--!nonstrict
-- Presence is observed state, independent of health, selection and presentation paging.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Store = Shim.load(base .. "/store.luau")
local View = Shim.load(base .. "/view.luau")
local failed = 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then print("PASS " .. name) else failed += 1 print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function state()
	local s = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end })
	s.active_root = "/work"
	s.workspaces = {
		{ name = "alpha", path = "/work/alpha", mountCount = 1 },
		{ name = "zulu", path = "/work/zulu", mountCount = 1 },
	}
	s.presence = {
		available = true, complete = false, host = 0,
		sessions = { { id = 1, host = 0, name = "Default" }, { id = 2, host = 0, name = "Review" } },
		tabs = { { id = 10, session = 2, name = "API" }, { id = 20, session = 1, name = "Tests" } },
		panes = {
			{ pane = 100, tab = 10, kind = "agent", cwd = "/work/zulu/src" },
			{ pane = 101, tab = 10, kind = "terminal", cwd = "/work/zulu" },
			{ pane = 200, tab = 20, kind = "terminal", cwd = "/work/zulu/tests" },
		},
	}
	return s
end
local function inspect(s)
	local main = View.render(s, {})
	local rows, texts, actions = {}, {}, {}
	local function walk(n)
		if type(n) ~= "table" then return end
		local p = n.p or {}
		if type(p.key) == "string" and string.sub(p.key, 1, 3) == "ws:" then rows[string.sub(p.key, 4)] = n end
		for _, span in p.spans or {} do table.insert(texts, span.t or "") end
		if p.text then table.insert(texts, p.text) end
		if p.title then table.insert(texts, p.title) end
		for _, action in p.actions or {} do if type(action) == "string" then actions[action] = n end end
		for _, child in n.c or {} do walk(child) end
	end
	walk(main)
	return rows, table.concat(texts, "\n"), actions
end

test("workspaces with observed tabs precede other workspaces", function()
	local s = state()
	local rows = View.filtered(s, "home")
	assert(rows[1].name == "zulu" and rows[2].name == "alpha", "Observed workspaces must be ordered before alphabetically earlier unobserved ones")
end)

test("presence exposes destinations and distinct tabs without counting splits twice", function()
	local _, text, actions = inspect(state())
	assert(actions["presence=zulu"], "An open workspace needs a separate presence action")
	assert(string.find(text, "Review", 1, true) and string.find(text, "Default", 1, true), "Presence must say where the workspace is open")
	assert(string.find(text, "2 tabs", 1, true), "Two panes in one tab must not inflate the tab count")
end)

test("the list groups observed workspaces without calling the rest closed", function()
	local _, text = inspect(state())
	assert(string.find(text, "Open in Tern", 1, true) and string.find(text, "Other workspaces", 1, true), "The presence groups must be visible")
	assert(not string.find(string.lower(text), "closed", 1, true), "Incomplete coverage cannot label workspaces closed")
end)

test("unobserved workspace presence remains explicitly uncertain", function()
	local rows = inspect(state())
	local row = rows.alpha
	local title = ""
	local function walk(n)
		if n.p and n.p.title then title ..= " " .. n.p.title end
		for _, c in n.c or {} do walk(c) end
	end
	walk(row)
	local t = string.lower(title)
	assert(string.find(t, "not observed", 1, true) or string.find(t, "unknown", 1, true), "A workspace unseen by this snapshot must not look globally confirmed closed")
end)

test("search still includes observed and unobserved matching workspaces", function()
	local s = state()
	s.filter = "alpha"
	local rows = View.filtered(s, "home")
	assert(#rows == 1 and rows[1].name == "alpha", "Presence must not hide matching unobserved workspaces")
end)

test("workspace names reach layout intact instead of being cut at a fixed length", function()
	local s = state()
	local name = "a-workspace-name-longer-than-thirty-two-characters-é-中文"
	s.workspaces = { { name = name, path = "/work/long", mountCount = 1 } }
	local rows = inspect(s)
	local names = {}
	local function walk(n)
		if n.p and n.p.role == "devcli.ws-name" then for _, span in n.p.spans or {} do table.insert(names, span.t) end end
		for _, c in n.c or {} do walk(c) end
	end
	walk(rows[name])
	assert(table.concat(names) == name, "The renderer truncated the name before the layout could use available width")
end)

test("unknown presence is visible without relying on a hover tooltip", function()
	local _, _, actions = inspect(state())
	local unknown = actions["presence=alpha"]
	assert(unknown and unknown.p.text == "?", "Incomplete visibility needs a visible unknown affordance, not an absent icon")
end)

process.exit(if failed == 0 then 0 else 1)
