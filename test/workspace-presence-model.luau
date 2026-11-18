--!nonstrict
-- Store.match_presence: distinct live tabs, deepest root, boundaries, case and unknown coverage.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Store = Shim.load(base .. "/store.luau")
local failed = 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then print("PASS " .. name) else failed += 1 print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function obs(panes, extra)
	local o = {
		available = true, complete = false, host = 0,
		sessions = { { id = 1, host = 0, name = "Default" }, { id = 2, host = 0, name = "Review" }, { id = 9, host = 1, name = "Remote" } },
		tabs = { { id = 10, session = 1, name = "A", pane = 100 }, { id = 20, session = 2, name = "B", pane = 200 }, { id = 90, session = 9, name = "R", pane = 900 } },
		panes = panes,
	}
	for k, v in extra or {} do o[k] = v end
	return o
end
local W = { { name = "app", path = "/work/app" }, { name = "app-sub", path = "/work/app/sub" }, { name = "ap", path = "/work/ap" } }

test("two splits of one tab count once", function()
	local m = Store.match_presence(W, obs({
		{ pane = 100, tab = 10, kind = "terminal", cwd = "/work/app" },
		{ pane = 101, tab = 10, kind = "agent", cwd = "/work/app/src" },
	}))
	local e = m["/work/app"]
	assert(e and e.count == 1 and #e.destinations == 1 and e.destinations[1].pane == 100)
end)

test("two sessions give two destinations", function()
	local m = Store.match_presence(W, obs({
		{ pane = 100, tab = 10, kind = "terminal", cwd = "/work/app" },
		{ pane = 200, tab = 20, kind = "terminal", cwd = "/work/app" },
	}))
	local e = m["/work/app"]
	assert(e.count == 2 and e.destinations[1].session_name == "Default" and e.destinations[2].session_name == "Review")
end)

test("plugin, browser, unknown, parked and other-host panes are ignored", function()
	local m = Store.match_presence(W, obs({
		{ pane = 100, tab = 10, kind = "plugin", cwd = "/work/app" },
		{ pane = 101, tab = 10, kind = "browser", cwd = "/work/app", url = "http://x" },
		{ pane = 102, tab = 10, cwd = "/work/app" },
		{ pane = 103, kind = "terminal", cwd = "/work/app", parked = true },
		{ pane = 900, tab = 90, kind = "terminal", cwd = "/work/app" },
	}))
	assert(next(m) == nil)
end)

test("native file paths count and prefixes respect directory boundaries and nesting", function()
	local m = Store.match_presence(W, obs({
		{ pane = 100, tab = 10, kind = "file", path = "/work/app/sub/x.lua" },
		{ pane = 200, tab = 20, kind = "terminal", cwd = "/work/app-other" },
	}))
	assert(m["/work/app/sub"] and m["/work/app/sub"].count == 1, "deepest root owns the path")
	assert(m["/work/app"] == nil and m["/work/ap"] == nil, "ancestors and sibling prefixes must not match")
end)

test("drive paths fold case and POSIX paths do not", function()
	local m = Store.match_presence({ { name = "w", path = "C:\\Work\\App" }, { name = "p", path = "/Work/App" } }, obs({
		{ pane = 100, tab = 10, kind = "terminal", cwd = "c:/work/app/src" },
		{ pane = 200, tab = 20, kind = "terminal", cwd = "/work/app" },
	}))
	assert(m[Store.norm("C:\\Work\\App")] and m[Store.norm("C:\\Work\\App")].count == 1)
	assert(m["/Work/App"] == nil)
end)

test("unknown coverage produces no claims", function()
	assert(next(Store.match_presence(W, nil)) == nil)
	assert(next(Store.match_presence(W, obs({ { pane = 100, tab = 10, kind = "terminal", cwd = "/work/app" } }, { available = false }))) == nil)
end)

test("presence_for follows observation and inventory changes", function()
	local s = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end })
	s.workspaces = { { name = "app", path = "/work/app" } }
	assert(Store.presence_for(s, s.workspaces[1]) == nil)
	Store.set_presence(s, obs({ { pane = 100, tab = 10, kind = "terminal", cwd = "/work/app" } }))
	assert(Store.presence_for(s, s.workspaces[1]).count == 1)
	s.workspaces = { { name = "app", path = "/elsewhere" } }
	assert(Store.presence_for(s, s.workspaces[1]) == nil)
end)

process.exit(if failed == 0 then 0 else 1)
