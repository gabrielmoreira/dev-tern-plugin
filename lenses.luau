--!nonstrict
-- Small terminal lenses for the human-readable dev workspace commands.
local ui = tern.ui
local Lenses = {}

local function trim(s: string): string
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function query(s: string): string
	return (s:gsub("([^%w%-_%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function absolute(path: string): boolean
	return path:match("^%a:[/\\]") ~= nil or path:match("^/") ~= nil or path:match("^\\\\[^\\]+\\[^\\]+") ~= nil
end

local function splitListRow(line: string)
	-- Split delimiters from the right: descriptions may themselves contain `|`.
	local p3 = line:match("^.*()|")
	if not p3 then return nil end
	local path = trim(line:sub(p3 + 1))
	local before = line:sub(1, p3 - 1)
	local p2 = before:match("^.*()|")
	if not p2 then return nil end
	local lastUsed = trim(before:sub(p2 + 1))
	before = before:sub(1, p2 - 1)
	local p1 = before:match("^.*()|")
	if not p1 then return nil end
	local mounts = trim(before:sub(p1 + 1))
	local label = trim(before:sub(1, p1 - 1))
	if label == "" or not mounts:match("^%d+$") or path == "" then return nil end
	local name, description = label:match("^(.-)%s+%-%s+(.+)$")
	if not name then name = label end
	if name == "" then return nil end
	return { name = name, description = description, mounts = tonumber(mounts), lastUsed = lastUsed, path = path }
end

local function gitPath(workspacePath: string?, mount: string): string?
	if not workspacePath or not absolute(workspacePath) or mount == "" then return nil end
	if mount:match("^[/\\]") or mount:match("^%a:") or mount:find(":", 1, true) then return nil end
	local normalized = mount:gsub("\\", "/")
	for part in normalized:gmatch("[^/]+") do
		if part == "." or part == ".." then return nil end
	end
	local separator = workspacePath:find("\\", 1, true) and "\\" or "/"
	return workspacePath:gsub("[/\\]+$", "") .. separator .. normalized:gsub("/", separator)
end

local function actionUrl(mode: string, name: string, path: string?): string
	local url = "devcli://" .. mode .. "?name=" .. query(name)
	if path then url ..= "&path=" .. query(path) end
	return url
end

local function listView(s)
	if not s.finished or s.status ~= 0 or #s.rows == 0 then return nil end
	local cards = {}
	for _, w in s.rows do
		local body = {}
		if w.description then table.insert(body, ui.text({ ui.span(w.description, "muted") })) end
		table.insert(body, ui.kv({
			{ ui.span("Mounts", "muted"), ui.span(tostring(w.mounts)) },
			{ ui.span("Last used", "muted"), ui.span(w.lastUsed) },
			{ ui.span("Path", "muted"), ui.span(w.path) },
		}))
		local buttons = {}
		if absolute(w.path) then
			table.insert(buttons, ui.button("Open workspace", { icon = "folder", actions = { click = "open=" .. actionUrl("open", w.name, w.path) } }))
		end
		table.insert(buttons, ui.button("Show", { icon = "folder", actions = { click = "show=" .. actionUrl("show", w.name, w.path) } }))
		table.insert(body, ui.row(buttons))
		table.insert(cards, ui.card({ ui.span(w.name) }, body, { icon = "layers", meta = ui.span(tostring(w.mounts) .. " mounts", "muted") }))
	end
	return ui.col(cards)
end

local function listLens()
	return {
		open = function(run, cx)
			return { rows = {}, header = false, recognized = false, finished = false, status = nil }
		end,
		line = function(s, l)
			local text = trim(l.text)
			if text:match("^Workspaces in .+:%s*$") then s.header = true; return end
			if text:match("^Workspace%s+|%s+Mounts%s+|%s+Last used%s+|%s+Path%s*$") then s.header = true; s.recognized = true; return end
			if s.header then
				local row = splitListRow(text)
				if row then table.insert(s.rows, row); s.recognized = true end
			end
		end,
		finish = function(s, status) s.finished = true; s.status = status end,
		view = function(s)
			if not s.recognized then return nil end
			return listView(s)
		end,
		event = function(s, ev, cx)
			if ev.ev == "action" and ev.value then cx:open(ev.value) end
		end,
	}
end

local function stateTone(state: string): string
	local value = state:lower()
	if value == "clean" or value == "matches your workspace plan" then return "success" end
	if value:find("dirty", 1, true) or value:find("diff", 1, true) or value:find("missing", 1, true) then return "warning" end
	return "muted"
end

local function statusView(s)
	if not s.finished or s.status ~= 0 or not s.workspace or not s.statusText or not s.recognized then return nil end
	local children = { ui.kv({
		{ ui.span("Path", "muted"), ui.span(s.path or "") },
		{ ui.span("Status", "muted"), ui.span(s.statusText, stateTone(s.statusText)) },
		{ ui.span("Mounts", "muted"), ui.span(tostring(#s.mounts)) },
	}) }
	table.insert(children, ui.badge(s.statusText, stateTone(s.statusText)))
	for _, m in s.mounts do
		local details = {}
		if m.repository then table.insert(details, ui.kv({ { ui.span("Repository", "muted"), ui.span(m.repository) } })) end
		if m.planned then table.insert(details, ui.kv({ { ui.span("Planned", "muted"), ui.span(m.planned) } })) end
		if m.checkedOut then table.insert(details, ui.kv({ { ui.span("Checked out", "muted"), ui.span(m.checkedOut) } })) end
		table.insert(details, ui.badge(m.state, stateTone(m.state)))
		local actions = {}
		local path = gitPath(s.path, m.name)
		if path then table.insert(actions, ui.button("Open repository", { icon = "folder", actions = { click = "open=devcli://git?path=" .. query(path) } })) end
		table.insert(actions, ui.button("Show workspace", { icon = "folder", actions = { click = "show=" .. actionUrl("show", s.workspace, s.path) } }))
		table.insert(details, ui.row(actions))
		table.insert(children, ui.card({ ui.span(m.name) }, details, { icon = "layers", meta = ui.span(m.state, "muted") }))
	end
	return ui.card({ ui.span(s.workspace) }, children, { icon = "layers", meta = "Workspace status" })
end

local function statusLens()
	return {
		open = function(run, cx)
			return { mounts = {}, finished = false, status = nil }
		end,
		line = function(s, l)
			local text = trim(l.text)
			local name = text:match("^Workspace:%s*(.+)$")
			if name then s.workspace = name end
			local path = text:match("^Path:%s*(.+)$")
			if path then s.path = path end
			local statusText = text:match("^Status:%s*(.-)%s*$")
			if statusText then s.statusText = statusText; s.recognized = true end
			local rowName, state = text:match("^[^%s]+%s+(.+)%s+%[([^%]]+)%]$")
			if rowName then
				table.insert(s.mounts, { name = rowName, state = state })
				s.current = #s.mounts
				s.recognized = true
			elseif s.current then
				local m = s.mounts[s.current]
				local value = text:match("^Repository:%s*(.+)$")
				if value then m.repository = value end
				value = text:match("^Planned:%s*(.+)$")
				if value then m.planned = value end
				value = text:match("^Checked out:%s*(.+)$")
				if value then m.checkedOut = value end
			end
		end,
		finish = function(s, status) s.finished = true; s.status = status end,
		view = function(s) return statusView(s) end,
		event = function(s, ev, cx)
			if ev.ev == "action" and ev.value then cx:open(ev.value) end
		end,
	}
end


local function commandMode(args: { string }): string?
	local first = if args[1] == "dev" then 2 else 1
	local mode, at
	if args[first] == "ls" then
		mode, at = "list", first + 1
	elseif args[first] == "ws" and args[first + 1] == "status" then
		mode, at = "status", first + 2
	else
		return nil
	end
	local positional = 0
	while at <= #args do
		local arg = args[at]
		if arg == "--root" or (mode == "status" and arg == "--ws") then
			if not args[at + 1] or args[at + 1]:match("^%-") then return nil end
			at += 2
		elseif arg:match("^%-%-root=.+") or (mode == "status" and arg:match("^%-%-ws=.+")) then
			at += 1
		elseif mode == "status" and (arg == "--offline" or arg == "--refresh") then
			at += 1
		elseif arg:match("^%-") then
			return nil -- JSON/help and unsupported formats retain their raw output
		else
			positional += 1
			if positional > 1 then return nil end
			at += 1
		end
	end
	return mode
end

local function open(run, cx)
	local mode = commandMode(run.args or {})
	local impl = if mode == "status" then statusLens() elseif mode == "list" then listLens() else nil
	return { impl = impl, data = impl and impl.open(run, cx) or nil }
end

tern.lens.define("dev", {
	open = open,
	line = function(s, l) if s.impl then s.impl.line(s.data, l) end end,
	finish = function(s, status) if s.impl then s.impl.finish(s.data, status) end end,
	view = function(s) return if s.impl then s.impl.view(s.data) else nil end,
	event = function(s, ev, cx)
		if s.impl and s.impl.event then s.impl.event(s.data, ev, cx) end
	end,
})
return Lenses
