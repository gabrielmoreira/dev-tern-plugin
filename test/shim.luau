--!nonstrict
-- A stand-in for Tern's `tern` global, enough to run the plugin's real modules under Lune against the real
-- dev executable: processes really run, timers really fire (polls longer than 5 s are recorded, not run),
-- UI builders return plain `{k, p, c}` nodes, and a fake window `cx` records every effect.

local process = require("@lune/process")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local task = require("@lune/task")
local luau = require("@lune/luau")

local Shim = {
	extra_env = {}, -- added to every dev process (isolated HOME / USERPROFILE)
	env_override = {}, -- what tern.getenv answers instead of the real environment
	pending = 0, -- process callbacks and short timers not yet run
	runs = {}, -- every argv started
	logs = {},
	kv = {},
	commands = {},
	handlers = {},
	blocks = {},
	route = nil,
	panes = {},
	lenses = {},
	files_buttons = {},
	status = nil,
	widgets = {},
	chrome_refreshes = 0,
}

local function merge(a, b)
	local out = {}
	for k, v in a or {} do
		out[k] = v
	end
	for k, v in b or {} do
		out[k] = v
	end
	return out
end

local function spans(value)
	if type(value) == "string" then
		return { { t = value } }
	elseif type(value) == "table" and value.t then
		return { value }
	end
	local out = {}
	for _, s in value or {} do
		table.insert(out, if type(s) == "string" then { t = s } else s)
	end
	return out
end

local ui = {}
function ui.span(t, s)
	return { t = t, s = s }
end
function ui.text(s)
	return { k = "text", p = { spans = spans(s) } }
end
for _, kind in { "col", "row", "lines" } do
	ui[kind] = function(children)
		return { k = kind, p = {}, c = children }
	end
end
function ui.card(head, children, props)
	return { k = "card", p = merge(props, { head = spans(head) }), c = children }
end
function ui.section(head, children)
	return { k = "section", p = { head = spans(head) }, c = children }
end
function ui.badge(t, tone)
	return { k = "badge", p = { text = t, tone = tone } }
end
function ui.button(text, props)
	return { k = "button", p = merge(props, { text = text }) }
end
function ui.code(text, lang)
	return { k = "code", p = { text = text, lang = lang } }
end
function ui.md(text)
	return { k = "md", p = { text = text } }
end
function ui.progress(value, label)
	return { k = "progress", p = { value = value, label = spans(label) } }
end
function ui.node(kind, props, children)
	return { k = kind, p = props or {}, c = children }
end
function ui.el(tag, props, children)
	return { k = "el", p = merge(props, { tag = tag }), c = children }
end
function ui.kv(items)
	local rows = {}
	for _, pair in items do
		table.insert(rows, ui.row({ ui.text(pair[1]), ui.text(pair[2]) }))
	end
	return ui.col(rows)
end

-- Short timers run; polls (1 s and longer) never fire, so settle() is not held open by a repeating tick.
local function timer(ms, fn)
	if ms >= 1000 then
		return { cancel = function() end }
	end
	Shim.pending += 1
	local done = false
	local thread = task.delay(ms / 1000, function()
		done = true
		Shim.pending -= 1
		fn(Shim.cx)
	end)
	return {
		cancel = function()
			if not done then
				done = true
				Shim.pending -= 1
				task.cancel(thread)
			end
		end,
	}
end

local function run(argv, opts, cb)
	if cb == nil and type(opts) == "function" then
		cb, opts = opts, nil
	end
	local program = argv[1]
	-- Count the run before any yielding call (Lune's fs is async), or settle() can return in the gap.
	Shim.pending += 1
	if string.find(program, "[/\\]") and not fs.isFile(program) then
		Shim.pending -= 1
		error("spawn failed: program not found: " .. program)
	end
	table.insert(Shim.runs, table.clone(argv))
	local args = table.move(argv, 2, #argv, 1, {})
	local trace = process.env.SHIM_DEBUG
	if trace then
		print("    [run] " .. table.concat(args, " ") .. "  pending=" .. Shim.pending)
	end
	if opts and opts.stdin then
		-- Lune's exec loses piped input across defer/pcall boundaries. Use explicit streams like Tern.
		local child = process.create(program, args, { cwd = opts.cwd, env = merge(opts.env, Shim.extra_env) })
		child.stdin:write(opts.stdin)
		child.stdin:close()
		task.defer(function()
			local stdout, stderr
			local out_done, err_done = false, false
			task.spawn(function() stdout = child.stdout:readToEnd(); out_done = true end)
			task.spawn(function() stderr = child.stderr:readToEnd(); err_done = true end)
			local status = child:status()
			while not (out_done and err_done) do task.wait(0.01) end
			Shim.pending -= 1
			cb({ status = status.code, stdout = stdout, stderr = stderr, timed_out = false }, Shim.cx)
		end)
		return
	end
	local function execute()
		local r = process.exec(program, args, {
			cwd = opts and opts.cwd,
			env = merge(opts and opts.env, Shim.extra_env),
			stdio = { stdin = opts and opts.stdin },
		})
		Shim.pending -= 1
		if trace then
			print("    [done] " .. tostring(args[1]) .. " " .. tostring(args[2]) .. " status=" .. r.code .. " pending=" .. Shim.pending)
		end
		cb({ status = r.code, stdout = r.stdout, stderr = r.stderr, timed_out = false }, Shim.cx)
	end
	task.defer(execute)
end

local function synchronous(fn, ...)
	Shim.pending += 1
	local ok, a = pcall(fn, ...)
	Shim.pending -= 1
	if not ok then
		error(a, 0)
	end
	return a
end

Shim.tern = {
	runtime = { os = process.os, jit = false },
	plugin = { id = "devcli" },
	context = "test",
	getenv = function(name)
		local o = Shim.env_override[name]
		if o ~= nil then
			return if o == false then nil else o
		end
		return process.env[name]
	end,
	-- Tern's fs is synchronous; Lune's yields. Each call counts as pending, so settle() cannot return while
	-- plugin code is suspended inside one.
	fs = {
		exists = function(p)
			return synchronous(function()
				return fs.isFile(p) or fs.isDir(p)
			end)
		end,
		read = function(p)
			return synchronous(fs.readFile, p)
		end,
		write = function(p, text)
			synchronous(fs.writeFile, p, text)
		end,
		list = function(p)
			local names = synchronous(fs.readDir, p)
			table.sort(names)
			return names
		end,
	},
	json = {
		encode = function(v, pretty)
			return serde.encode("json", v, pretty == true)
		end,
		-- Like Tern: arrays come back tagged with a protected metatable (table.clone refuses them).
		decode = function(s)
			local function tag(v)
				if type(v) ~= "table" then
					return v
				end
				for k, x in v do
					v[k] = tag(x)
				end
				if #v > 0 then
					setmetatable(v, { __metatable = "json array" })
				end
				return v
			end
			return tag(serde.decode("json", s))
		end,
	},
	process = { run = run },
	timer = timer,
	now = function()
		return os.clock() * 1000
	end,
	kv = {
		get = function(k)
			return Shim.kv[k]
		end,
		set = function(k, v)
			Shim.kv[k] = v
		end,
	},
	log = {
		warn = function(...)
			table.insert(Shim.logs, table.concat({ ... }, " "))
		end,
		info = function() end,
		debug = function() end,
		error = function(...)
			table.insert(Shim.logs, table.concat({ ... }, " "))
		end,
	},
	ui = ui,
	chrome = {
		status = function(fn)
			Shim.status = fn
		end,
		widget = function(id, spec)
			Shim.widgets[id] = spec
		end,
		refresh = function()
			Shim.chrome_refreshes += 1
		end,
	},
	files = {
		button = function(def)
			Shim.files_buttons[def.id] = def
		end,
	},
	lens = {
		define = function(id, def)
			Shim.lenses[id] = def
		end,
	},
	command = function(def)
		Shim.commands[def.id] = def
	end,
	bind = function() end,
	on = function(name, fn)
		Shim.handlers[name] = Shim.handlers[name] or {}
		table.insert(Shim.handlers[name], fn)
	end,
	route = {
		link = function(fn)
			Shim.route = fn
		end,
		open = function() end,
	},
	block = {
		define = function(id, def)
			Shim.blocks[id] = def
		end,
	},
	pane = {
		list = function()
			return Shim.panes
		end,
	},
}

-- Loads a plugin file with `tern` and a relative `require` in its environment, as Tern does.
local cache = {}
function Shim.load(path: string)
	path = string.gsub(path, "\\", "/")
	if cache[path] then
		return cache[path]
	end
	local dir = string.match(path, "^(.*)/[^/]*$") or "."
	local env = setmetatable({
		tern = Shim.tern,
		require = function(rel)
			local target = rel
			if string.sub(rel, 1, 2) == "./" then
				target = dir .. "/" .. string.sub(rel, 3)
			end
			if not string.match(target, "%.luau$") then
				target ..= ".luau"
			end
			return Shim.load(target)
		end,
	}, { __index = _G })
	local fn = luau.load(luau.compile(fs.readFile(path)), { debugName = path, environment = env })
	local result = fn()
	cache[path] = result
	return result
end

-- Waits until every process callback and short timer has run.
function Shim.settle(limit_s: number?)
	local deadline = os.clock() + (limit_s or 120)
	task.wait(0.05)
	while Shim.pending > 0 do
		if os.clock() > deadline then
			error("settle timed out with " .. Shim.pending .. " pending")
		end
		task.wait(0.05)
	end
end

-- A fake WindowCx recording what the plugin asks the window to do.
function Shim.window_cx()
	local cx = { record = { toasts = {}, copies = {}, sessions = {}, switched = {}, git = {}, blocks = {}, opened = {}, closed = {}, docs = {} } }
	local canvases = {}
	local next_pane = 100
	cx.canvases = canvases
	cx.native_panes = {}
	cx.record.events, cx.record.moves, cx.record.parked = {}, {}, {}
	cx.canvas = {
		list = function()
			local out = {}
			for pane, c in canvases do
				table.insert(out, { pane = pane, title = c.title, owner = "devcli", about = c.about })
			end
			return out
		end,
		open = function(_, spec)
			next_pane += 1
			canvases[next_pane] = { title = spec.title, about = spec.about, view = spec.view, dock = spec.dock, spec = spec }
			return next_pane
		end,
		set = function(_, pane, change)
			local c = canvases[pane]
			if not c then
				error("no canvas " .. tostring(pane))
			end
			c.view = change.view or c.view
			c.dock = change.dock or c.dock
			c.sets = (c.sets or 0) + 1
		end,
		get = function(_, pane)
			return canvases[pane]
		end,
	}
	cx.session = {
		focused = function()
			return 1
		end,
		tab_of = function(_, pane)
			local p = cx.native_panes[pane]
			return if pane == 1 then (cx.tab or 7) elseif p and not p.info.parked then p.info.tab elseif canvases[pane] then 7 else nil
		end,
		layout = function(_, tab)
			return if tab == 7 then { root = { pane = 1 } } else nil
		end,
		pane = function(_, pane)
			return if pane == 1 then { pane = 1, tab = cx.tab or 7, cwd = cx.cwd or "C:/" } elseif cx.native_panes[pane] then cx.native_panes[pane].info else nil
		end,
		panes = function()
			local out = { { pane = 1, tab = cx.tab or 7, cwd = cx.cwd or "C:/" } }
			for _, entry in cx.native_panes do table.insert(out, entry.info) end
			return out
		end,
	}
	cx.session.tabs = function() return { { id = cx.tab or 7, session = 1 } } end
	cx.session.event = function(_, pane, event)
		table.insert(cx.record.events, { pane = pane, event = event })
		local entry = cx.native_panes[pane]
		if entry and entry.def and entry.state then entry.def.event(entry.state, event, entry.cx) end
	end
	cx.layout = {
		close = function(_, pane)
			canvases[pane] = nil
			table.insert(cx.record.closed, pane)
		end,
		focus = function() end,
	}
	cx.layout.move = function(_, pane, target, dir, opts)
		table.insert(cx.record.moves, { pane = pane, target = target, dir = dir, opts = opts })
		local entry = cx.native_panes[pane]
		if entry then entry.info.tab = cx.tab or 7 end
		return true
	end
	cx.layout.resize = function(_, pane, _dir, cells)
		local entry = cx.native_panes[pane]
		if not entry or not entry.state or not entry.def.resize then return false end
		entry.def.resize(entry.state, (entry.state.cols or 80) + cells, 30, entry.cx)
		return true
	end
	cx.layout.park = function(_, pane)
		local entry = cx.native_panes[pane]
		if entry then entry.info.parked, entry.info.tab = true, nil end
		table.insert(cx.record.parked, pane)
		return true
	end
	cx.layout.unpark = function(_, pane)
		local entry = cx.native_panes[pane]
		if entry then entry.info.parked, entry.info.tab = false, cx.tab or 7 end
		return true
	end
	cx.sessions = {
		current = function() return { id = 1, host = 0, name = "Default", current = true } end,
		list = function()
			return cx.existing_sessions or {}
		end,
		create = function(_, opts)
			table.insert(cx.record.sessions, opts)
			local session = { id = #cx.record.sessions + 10, name = opts.name, host = 0 }
			cx.existing_sessions = cx.existing_sessions or {}
			table.insert(cx.existing_sessions, session)
			return session
		end,
		switch = function(_, id)
			table.insert(cx.record.switched, id)
		end,
	}
	cx.git = {
		open = function(_, path, opts)
			table.insert(cx.record.git, { path = path, opts = opts })
			return {
				next = function(_, fn)
					fn(1, nil, cx)
				end,
			}
		end,
	}
	-- An already-settled Awaitable: `:next(fn)` calls fn(value, failure, cx) at once.
	local function settled(value, failure)
		return {
			next = function(_, fn)
				fn(value, failure, cx)
			end,
		}
	end
	-- Documents like Tern's: an opened file gets a live buffer; read/write go to the buffer when open (unsaved
	-- until save) and to disk otherwise.
	cx.docs = {
		buffers = {},
		open = function(self, path, opts)
			table.insert(cx.record.docs, { path = path, opts = opts })
			if not self.buffers[path] and synchronous(fs.isFile, path) then
				self.buffers[path] = { text = synchronous(fs.readFile, path), dirty = false }
			end
			return 77
		end,
		read = function(self, path)
			local b = self.buffers[path]
			if b then
				return settled(b.text, nil)
			end
			local ok, text = pcall(synchronous, fs.readFile, path)
			return if ok then settled(text, nil) else settled(nil, tostring(text))
		end,
		write = function(self, path, text)
			local b = self.buffers[path]
			if b then
				b.text, b.dirty = text, true
			else
				synchronous(fs.writeFile, path, text)
			end
			return settled({ from = 1, to = 1 }, nil)
		end,
		save = function(self, path)
			local b = self.buffers[path]
			if b and b.dirty then
				synchronous(fs.writeFile, path, b.text)
				b.dirty = false
			end
			return settled(true, nil)
		end,
	}
	cx.record.prompts = {}
	-- What the next prompt answers (nil: dismissed).
	cx.prompt_answer = nil
	function cx:prompt(opts)
		table.insert(self.record.prompts, opts)
		return settled(self.prompt_answer, nil)
	end
	cx.record.picks = {}
	cx.pick_answers = {}
	function cx:pick(opts)
		table.insert(self.record.picks, opts)
		local answer = table.remove(self.pick_answers, 1)
		if type(answer) == "number" then
			answer = opts.items[answer]
		end
		return settled(answer, nil)
	end
	function cx:toast(level, text, sub)
		table.insert(self.record.toasts, { level = level, text = text, sub = sub })
	end
	function cx:copy(text)
		table.insert(self.record.copies, text)
	end
	function cx:new_block(kind, args, how, opts)
		table.insert(self.record.blocks, { kind = kind, args = args, how = how, opts = opts })
		next_pane += 1
		local pane = next_pane
		local def = Shim.blocks[string.match(kind, "%.([^%.]+)$") or kind]
		local entry = { def = def, info = { pane = pane, block = kind, kind = "plugin", tab = cx.tab or 7, title = "dev" } }
		self.native_panes[pane] = entry
		table.insert(Shim.panes, entry.info)
		local block_cx = { pane = pane, frame = function() end }
		function block_cx:render()
			if entry.state then entry.view = def.view(entry.state, self) end
		end
		function block_cx:open(url)
			if Shim.route then Shim.route({ url = url, pane = pane }, cx) end
		end
		function block_cx:toast(...) cx:toast(...) end
		function block_cx:copy(text) cx:copy(text) end
		entry.cx = block_cx
		if def then
			entry.state = def.init(block_cx, args or {}, nil)
			if def.resize then def.resize(entry.state, 80, 30, block_cx) end
			block_cx:render()
		end
		return pane
	end
	function cx:open(target)
		table.insert(self.record.opened, target)
	end
	return cx
end

return Shim
