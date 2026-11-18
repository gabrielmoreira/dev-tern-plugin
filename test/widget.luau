--!nonstrict
-- The widget switches existing destinations across roots; it never opens a replacement tab.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Dev = Shim.load(base .. "/devcli.luau")
local alpha = { name = "alpha", path = "/widget-default/alpha" }
local nested = { name = "nested", path = "/widget-default/alpha/nested" }
local beta = { name = "alpha", path = "/widget-extra/alpha" }
local closed = { name = "not-observed", path = "/widget-default/not-observed" }
Dev.roots = function(_, done)
	done({ ok = true, value = { { path = "/widget-default" }, { path = "/widget-extra" } } }, nil)
end
Dev.workspaces = function(input, done)
	done({ ok = true, value = if input.root == "/widget-extra" then { beta } else { alpha, nested, closed } }, nil)
end
Shim.load(base .. "/window.luau")
local function world()
	local cx = Shim.window_cx()
	local state = { current = 1, focused = 100, tabs = { { id = 10, session = 1 }, { id = 20, session = 2 } }, panes = {
		{ pane = 100, tab = 10, kind = "terminal", cwd = alpha.path .. "/src" },
		{ pane = 200, tab = 20, kind = "agent", cwd = beta.path },
	} }
	cx.sessions.current = function() return { id = state.current, host = 0, name = "Session " .. state.current } end
	cx.sessions.list = function() return { { id = 1, host = 0, name = "First" }, { id = 2, host = 0, name = "Second" } } end
	cx.sessions.switch = function(_, id) state.current = id end
	cx.session.tabs = function() return state.tabs end
	cx.session.panes = function() return state.panes end
	cx.session.focused = function() return state.focused end
	cx.layout.focus = function(_, pane) state.focused = pane end
	cx.layout.new_tab = function() error("The widget must not create a tab") end
	cx.sessions.create = function() error("The widget must not create a session") end
	return cx, state
end
local function menu(cx)
	Shim.commands.menu.run(cx)
end
local failures = 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then print("PASS " .. name) else failures += 1 print("FAIL " .. name .. ": " .. tostring(why)) end
end

test("a reloaded widget VM prepares its preview without window_start", function()
	Shim.cx = world()
	Shim.settle()
	local title = Shim.widgets.dev.render(nil).title
	assert(string.find(title, closed.name, 1, true) and string.find(title, beta.path, 1, true),
		"A reloaded widget VM must load its preview without waiting for a new window_start event")
end)

test("hover previews all roots from cache with observed workspaces first", function()
	local cx, state = world()
	Shim.cx = cx
	Shim.kv.sidebar = false
	local current, mirrors = Dev.current, Dev.mirrors
	Dev.current = function(_, done) done({ ok = true, value = { root = "/widget-default" } }, cx) end
	Dev.mirrors = function(_, done) done({ ok = true, value = {} }, cx) end
	for _, handler in Shim.handlers.window_start do handler(cx) end
	Shim.settle()
	Dev.current, Dev.mirrors = current, mirrors
	local roots, workspaces = Dev.roots, Dev.workspaces
	Dev.roots = function() error("Rendering a cached preview must not read roots") end
	Dev.workspaces = function() error("Rendering a cached preview must not read workspaces") end
	local ok, why = pcall(function()
		local title = Shim.widgets.dev.render(nil).title
		local first = string.find(title, alpha.path, 1, true)
		local second = string.find(title, beta.path, 1, true)
		local unopened = string.find(title, closed.name, 1, true)
		local child = string.find(title, nested.name, 1, true)
		assert(first and second and unopened and child,
			"The cached hover preview must include unopened workspaces and distinguish equal names across roots")
		assert(first < unopened and second < unopened and first < child and second < child,
			"Observed workspaces must precede unobserved workspaces in the hover preview")
		assert(#cx.record.picks == 0, "Loading the hover preview must not open a picker")
		state.panes[1].cwd = closed.path
		for _, handler in Shim.handlers.cwd do handler({}, cx) end
		Shim.settle()
		title = Shim.widgets.dev.render(nil).title
		assert(string.find(title, closed.name, 1, true) < string.find(title, alpha.path, 1, true),
			"The hover preview did not update its observed order after a native CWD change")
	end)
	Dev.roots, Dev.workspaces = roots, workspaces
	assert(ok, why)
end)

test("the hover preview stays short when many workspaces are registered", function()
	local cx = world()
	local many = {}
	for i = 1, 12 do
		table.insert(many, { name = string.format("ws-%02d", i), path = "/widget-default/ws-" .. i })
	end
	local workspaces = Dev.workspaces
	Dev.workspaces = function(_, done) done({ ok = true, value = many }, nil) end
	cx.pick = function(_, opts) return { next = function() end } end
	menu(cx)
	Dev.workspaces = workspaces
	local lines = {}
	for line in string.gmatch(Shim.widgets.dev.render(nil).title, "[^\n]+") do table.insert(lines, line) end
	assert(#lines == 9, "The hover preview must cap its rows, not list every workspace: " .. #lines .. " lines")
	assert(lines[9] == "+4 more", "The hover preview must count the hidden workspaces: " .. tostring(lines[9]))
end)

test("selecting another root's open workspace focuses its existing pane", function()
	local cx, state = world()
	cx.pick = function(_, opts)
		table.insert(cx.record.picks, opts)
		local chosen
		for _, item in opts.items do if string.find(item.detail or "", beta.path, 1, true) then chosen = item end end
		assert(chosen, "The selector omitted an open workspace outside the default root")
		return { next = function(_, fn) fn(chosen, nil, cx) end }
	end
	menu(cx)
	assert(state.current == 2 and state.focused == 200, "The existing workspace destination was not focused")
	assert(#state.tabs == 2, "Switching duplicated a workspace tab")
end)

test("the selector lists every registered workspace with active and observed ones first", function()
	local cx = world()
	menu(cx)
	local items = cx.record.picks[1].items
	assert(#items == 4, "The menu omitted registered workspaces that are not open")
	assert(items[1].current == true and string.find(items[1].detail, alpha.path, 1, true), "The active workspace must lead the workspace choices")
	assert(items[2].observed == true, "Other open workspaces must precede unobserved workspaces")
	local found = false
	for _, item in items do if item.label == closed.name then found = true end end
	assert(found, "A registered workspace was omitted merely because it is not open")
end)

test("nested workspace ownership marks only the deepest workspace as observed", function()
	local cx, state = world()
	state.panes[1].cwd = nested.path .. "/src"
	state.panes[2] = nil
	menu(cx)
	local items = cx.record.picks[1].items
	assert(items[1].label == nested.name and items[1].observed == true, "The nested workspace must be recognized as open")
	for _, item in items do
		if item.workspace.path == alpha.path then assert(item.observed == false, "The parent was incorrectly recognized as open") end
	end
end)

test("a destination closed while the picker is open is not replaced", function()
	local cx, state = world()
	local selected, pending
	cx.pick = function(_, opts)
		for _, item in opts.items do if string.find(item.detail or "", beta.path, 1, true) then selected = item end end
		return { next = function(_, fn) pending = fn end }
	end
	menu(cx)
	assert(selected and pending, "No open destination was offered")
	state.tabs[2], state.panes[2] = nil, nil
	pending(selected, nil, cx)
	assert(state.current == 1 and state.focused == 100, "A stale destination changed the active workspace")
end)

test("a CLI callback uses its live context after the click context expires", function()
	local clicked, state = world()
	local live = world()
	live.session.tabs = clicked.session.tabs
	live.session.panes = clicked.session.panes
	live.session.focused = clicked.session.focused
	live.sessions.current = clicked.sessions.current
	live.sessions.list = clicked.sessions.list
	live.sessions.switch = clicked.sessions.switch
	live.layout.focus = clicked.layout.focus
	local pending
	local roots = Dev.roots
	Dev.roots = function(_, done) pending = done end
	menu(clicked)
	Dev.roots = roots
	clicked.session = setmetatable({}, { __index = function() error("userdata has been destructed") end })
	clicked.sessions = clicked.session
	clicked.pick = function() error("userdata has been destructed") end
	pending({ ok = true, value = { { path = "/widget-default" } } }, live)
	assert(#live.record.picks == 1, "The selector used the expired click context")
	assert(state.current == 1, "Opening the selector must not switch sessions")
end)

test("the widget toggles immediately while CLI inventory is still pending", function()
	local cx = Shim.window_cx()
	Shim.cx = cx
	Shim.kv.sidebar, Shim.kv.surface = false, nil
	local roots = Dev.roots
	Dev.roots = function() end
	local view = Shim.widgets.dev.render(nil)
	local id = string.match(view.command, "^plugin%.devcli%.(.+)$")
	Shim.commands[id].run(cx)
	Dev.roots = roots
	assert(next(cx.native_panes) ~= nil and Shim.kv.sidebar == true,
		"Widget click waited for CLI inventory instead of opening the sidebar immediately")
	assert(#cx.record.picks == 0, "Widget click must not open an intermediate Show/Hide picker")
	Shim.commands[id].run(cx)
	assert(Shim.kv.sidebar == false, "The next widget click must hide the sidebar")
end)

assert(failures == 0, tostring(failures) .. " widget scenarios failed")
