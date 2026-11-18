--!nonstrict
-- Workspace destinations are chosen explicitly; opening never invents a session name.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
Shim.load(base .. "/window.luau")
local failed = 0
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then print("PASS " .. name) else failed += 1 print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function world()
	local cx = Shim.window_cx()
	local state = { current = 1, host = 0, panes = {}, tabs = {}, focused = nil, created = {}, sessions = {
		{ id = 1, host = 0, name = "Default", current = true },
		{ id = 2, host = 0, name = "Review", current = false },
	} }
	cx.sessions.current = function() return { id = state.current, host = state.host, name = if state.current == 1 then "Default" else "Review" } end
	cx.sessions.list = function() return state.sessions end
	cx.sessions.switch = function(_, id) state.current = id end
	cx.sessions.create = function(_, opts)
		local id = 100 + #state.created
		local session = { id = id, host = 0, name = opts.name }
		table.insert(state.created, session)
		table.insert(state.sessions, session)
		state.current = id
		table.insert(state.tabs, { id = 200 + #state.tabs, session = id, cwd = opts.cwd })
		return session
	end
	cx.session.tabs = function() return state.tabs end
	cx.session.panes = function() return state.panes end
	cx.layout.new_tab = function(_, launch)
		local tab = { id = 200 + #state.tabs, session = state.current, cwd = launch.cwd }
		table.insert(state.tabs, tab)
		return tab.id
	end
	cx.layout.focus = function(_, pane) state.focused = pane end
	local answers = {}
	cx.answer = function(label) table.insert(answers, label) end
	cx.pick = function(_, opts)
		table.insert(cx.record.picks, opts)
		local label = table.remove(answers, 1)
		local selected = nil
		for _, item in opts.items do if item.label == label then selected = item break end end
		return { next = function(_, fn) fn(selected, nil, cx) end }
	end
	return cx, state
end
local function open(cx)
	Shim.route({ url = "devcli://open?name=api-cleanup&path=%2Fwork%2Fapi-cleanup" }, cx)
end

test("cancelling destination selection does not create a session", function()
	local cx, state = world()
	open(cx)
	assert(#state.created == 0 and #cx.record.sessions == 0, "Opening silently created a session instead of asking")
	assert(#cx.record.picks == 1, "The session destination picker did not appear")
end)

test("choosing an existing session opens the workspace there", function()
	local cx, state = world()
	cx.answer("Review")
	open(cx)
	assert(state.current == 2, "The selected session was not shown")
	assert(#state.tabs == 1 and state.tabs[1].session == 2 and state.tabs[1].cwd == "/work/api-cleanup", "The workspace tab was not opened in the chosen session")
	assert(#state.created == 0 and #cx.record.sessions == 0, "An existing destination must not create another session")
end)

test("the Default destination is offered only once", function()
	local cx = world()
	open(cx)
	local picker = cx.record.picks[1]
	assert(picker, "No destination choices were offered")
	local count = 0
	for _, item in picker.items do if item.label == "Default" then count += 1 end end
	assert(count == 1, "Default must be one real session choice, not duplicated as an alias")
end)

test("a new session uses the name entered by the user", function()
	local cx, state = world()
	cx.answer("New session…")
	cx.prompt_answer = "Release review"
	open(cx)
	assert(#state.created == 1 and state.created[1].name == "Release review", "The session name must come from the prompt, not the workspace")
	assert(state.tabs[1].cwd == "/work/api-cleanup", "The first tab must start at the workspace")
	assert(cx.record.prompts[1] and (cx.record.prompts[1].value == nil or cx.record.prompts[1].value == ""), "The name prompt must not prefill the workspace name")
end)

test("cancelling a new session name leaves existing sessions unchanged", function()
	local cx, state = world()
	cx.answer("New session…")
	open(cx)
	assert(#state.created == 0 and #cx.record.sessions == 0 and #state.tabs == 0, "A cancelled name prompt must not create anything")
end)

test("an existing tab in the chosen session is focused instead of duplicated", function()
	local cx, state = world()
	state.tabs = { { id = 10, session = 2, name = "API" } }
	state.panes = { { pane = 100, tab = 10, kind = "terminal", cwd = "/work/api-cleanup" } }
	cx.answer("Review")
	open(cx)
	assert(state.current == 2 and state.focused == 100 and #state.tabs == 1, "Opening must reveal the existing workspace tab in the selected session")
end)

test("a root change while the destination picker is open cancels the old action", function()
	local cx, state = world()
	local pending, items
	cx.pick = function(_, opts)
		items = opts.items
		return { next = function(_, fn) pending = fn end }
	end
	open(cx)
	Shim.kv.root = "/another-root"
	pending(items[1], nil, cx)
	Shim.kv.root = nil
	assert(#state.created == 0 and #state.tabs == 0, "A stale picker must not open a workspace from the old root")
end)

test("presence selection cannot cross into a different host with reused numeric ids", function()
	local cx, state = world()
	state.tabs = { { id = 10, session = 1, name = "API" }, { id = 20, session = 2, name = "Tests" } }
	state.panes = {
		{ pane = 100, tab = 10, kind = "terminal", cwd = "/work/api-cleanup" },
		{ pane = 200, tab = 20, kind = "terminal", cwd = "/work/api-cleanup" },
	}
	local pending, items
	cx.pick = function(_, opts)
		items = opts.items
		return { next = function(_, fn) pending = fn end }
	end
	Shim.route({ url = "devcli://presence?name=api-cleanup&path=%2Fwork%2Fapi-cleanup" }, cx)
	assert(pending and #items == 2, "The two observed tabs must be offered")
	state.host = 1
	state.sessions = { { id = 1, host = 1, name = "Remote" }, { id = 2, host = 1, name = "Other" } }
	pending(items[1], nil, cx)
	assert(state.focused == nil and state.current == 1, "A host change must not redirect an old tab choice to a different machine")
end)

test("Default stays easy to find even when native session order changes", function()
	local cx, state = world()
	state.sessions = { state.sessions[2], state.sessions[1] }
	open(cx)
	assert(cx.record.picks[1].items[1].label == "Default", "The real Default session should lead the ordinary destination choices")
end)

test("a colliding new name offers the existing session without creating a suffix", function()
	local cx, state = world()
	cx.answer("New session…")
	cx.answer("Use existing “Review”")
	cx.prompt_answer = "review"
	open(cx)
	assert(#state.created == 0 and state.current == 2 and #state.tabs == 1, "A name collision must resolve to the chosen existing session, not invent another name")
end)

test("a blank new session name cannot create a session", function()
	local cx, state = world()
	cx.answer("New session…")
	cx.prompt_answer = "  "
	open(cx)
	assert(#state.created == 0 and #state.tabs == 0, "Blank input must not create an automatically named session")
end)

process.exit(if failed == 0 then 0 else 1)
