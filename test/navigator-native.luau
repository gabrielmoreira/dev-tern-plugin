--!nonstrict
-- Native dialog cancellation must retain the inspected collection and its query.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Dev = Shim.load(base .. "/devcli.luau")
local function answer(value)
	return function(_, done) done({ ok = true, value = value }, nil) end
end
Dev.roots = answer({})
Dev.current = answer({ root = "/navigator-fixture", source = "default" })
Dev.workspaces = answer({})
Dev.mirrors = answer({})
Dev.worksets = answer({})
Dev.labels = answer({})
Dev.catalog = answer({})
Shim.load(base .. "/host.luau")
local panel = Shim.blocks.panel
local cx = { pane = 880, render = function() end, frame = function() end, open = function() end, toast = function() end }
table.insert(Shim.panes, { pane = cx.pane })
local state = panel.init(cx, {}, nil)
panel.resize(state, 80, 30, cx)
state.store.screen = "prs"
state.fields.f_filter = { text = "review é😀", cursor = #"review é😀" }
panel.event(state, { ev = "action", act = "create" }, cx)
assert(state.store.screen == "prs", "Opening New must not replace the inspected pull-request collection")
assert(#panel.view(state, cx).layer.c > 0, "New must be a floating dialog above the existing collection")
panel.key(state, { name = "escape" }, cx)
assert(state.store.modal == nil, "Escape must dismiss New")
assert(state.store.screen == "prs", "Cancel must return to the inspected pull-request collection")
assert(state.fields.f_filter.text == "review é😀", "Cancel must preserve the collection query, including Unicode")
panel.event(state, { ev = "action", act = "settings" }, cx)
assert(#panel.view(state, cx).layer.c > 0, "Settings must float over the same inspected collection")
panel.key(state, { name = "escape" }, cx)
assert(#panel.view(state, cx).layer.c == 0 and state.store.screen == "prs", "Escape must clear the dialog region without navigation")
for _ = 1, 3 do
	panel.event(state, { ev = "action", act = "settings" }, cx)
	panel.event(state, { ev = "action", act = "modal.close" }, cx)
	assert(#panel.view(state, cx).layer.c == 0, "Closing Settings must publish an empty layer, not retain its sheet")
	assert(state.fields.f_filter.text == "review é😀", "Repeated dialog dismissal must preserve the inspected query")
end
print("native modal context retained")

-- Placement and visibility survive focus changes in different sessions.
Shim.load(base .. "/window.luau")
local function focus(window)
	Shim.cx = window
	for _, handler in Shim.handlers.focus or {} do handler({}, window) end
	Shim.settle()
end
local failures = {}
local function expect(ok, message)
	if not ok then table.insert(failures, message) end
end
local first = Shim.window_cx()
Shim.cx = first
Shim.kv.sidebar, Shim.kv.surface = false, nil
Shim.commands.sidebar.run(first)
Shim.settle()
local first_pane, first_entry = next(first.native_panes)
local second = Shim.window_cx()
second.sessions.current = function() return { id = 2, host = 0, name = "Second" } end
second.session.tabs = function() return { { id = 7, session = 2 } } end
focus(second)
local _, second_entry = next(second.native_panes)
assert(second_entry, "Enabled sidebar must appear when another session receives focus")
Shim.commands.sidebar.run(second)
expect(second_entry.info.parked == true, "Hide must park the current session's navigator")
focus(first)
expect(first_entry.info.parked == true, "Returning to another session after Hide must not reveal its old sidebar")
Shim.commands.sidebar.run(first)
Shim.commands.panel.run(first)
local placement = first.record.moves[#first.record.moves]
expect(placement and placement.pane == first_pane and placement.dir == "right", "Open panel must place the reused navigator to the right")
first.tab = 8
local moves = #first.record.moves
focus(first)
expect(first_entry.info.tab == 7 and #first.record.moves == moves, "Explicit panel placement must not resume sidebar following on focus")
assert(#failures == 0, table.concat(failures, "\n"))
print("native navigator placement and cross-session hiding retained")

-- The sidebar's edge is a preference, not the side of whichever pane has focus.
local edge = Shim.window_cx()
Shim.cx = edge
Shim.kv.sidebar, Shim.kv.surface, Shim.kv.sidebar_side = false, nil, nil
local content = { split = "right", ratio = 0.5, { pane = 1 }, { split = "down", { pane = 2 }, { pane = 3 } } }
edge.session.layout = function() return { root = content } end
Shim.commands.sidebar.run(edge)
Shim.settle()
local created = edge.record.blocks[#edge.record.blocks]
local edge_pane = next(edge.native_panes)
local edge_failures = {}
local function edge_expect(ok, message)
	if not ok then table.insert(edge_failures, message) end
end
edge_expect(created.opts.dir == "right", "Sidebar must default to the right, without a saved preference")
edge_expect(created.opts.target == 3, "Sidebar must use the outer content edge, not the focused left pane")
edge.tab = 8
focus(edge)
local moved = edge.record.moves[#edge.record.moves]
edge_expect(moved and moved.dir == "right" and moved.target == 3 and edge.native_panes[edge_pane].info.tab == 8,
	"Following another tab must retain the right edge without creating a second navigator")
Shim.route({ url = "devcli://sidebar.side?value=left" }, edge)
edge_expect(Shim.kv.sidebar_side == "left", "Choosing Left must persist the side preference")
moved = edge.record.moves[#edge.record.moves]
edge_expect(moved and moved.dir == "left" and moved.target == 1, "Changing side must reposition the existing navigator")
edge.tab = 9
focus(edge)
moved = edge.record.moves[#edge.record.moves]
edge_expect(moved and moved.dir == "left" and moved.target == 1, "The saved Left preference must survive tab changes")
assert(#edge_failures == 0, table.concat(edge_failures, "\n"))
print("sidebar default, edge placement and side preference retained")

-- Default sizing is measured in terminal cells, and does not fight a later manual resize.
local sized = Shim.window_cx()
sized.session.layout = function() return { root = { pane = 1 } } end
local event = sized.session.event
local mounting = true
sized.session.event = function(self, pane, ev)
	if mounting and ev.act == "sidebar.measure" then mounting = false return end
	event(self, pane, ev)
end
local resizes = {}
sized.layout.resize = function(_, pane, dir, cells)
	local entry = sized.native_panes[pane]
	table.insert(resizes, { dir = dir, cells = cells })
	panel.resize(entry.state, entry.state.cols + cells, 30, entry.cx)
	return true
end
Shim.cx = sized
Shim.kv.sidebar, Shim.kv.surface, Shim.kv.sidebar_side = false, nil, nil
Shim.commands.sidebar.run(sized)
Shim.settle()
local sized_pane, sized_entry = next(sized.native_panes)
assert(#resizes == 1 and resizes[1].dir == "left" and resizes[1].cells == -34,
	"A new right sidebar must shrink from 80 to 46 terminal columns")
panel.resize(sized_entry.state, 61, 30, sized_entry.cx)
focus(sized)
assert(#resizes == 1, "Ordinary focus and manual resizing must not force the default width again")
local default_move = sized.layout.move
sized.layout.move = function(self, pane, target, dir, opts)
	local ok = default_move(self, pane, target, dir, opts)
	panel.resize(sized_entry.state, 80, 30, sized_entry.cx)
	return ok
end
sized.tab = 8
focus(sized)
assert(sized_entry.state.cols == 61, "Moving to another tab must preserve the manually chosen width")
panel.resize(sized_entry.state, 61, 30, sized_entry.cx)
Shim.route({ url = "devcli://sidebar.side?value=left" }, sized)
Shim.settle()
assert(resizes[#resizes].dir == "right", "A left sidebar must resize toward the content on its right")
assert(sized_entry.state.cols == 61, "Changing sides must preserve the manually chosen width")
panel.resize(sized_entry.state, 46, 30, sized_entry.cx)
local move = sized.layout.move
sized.layout.move = function(self, pane, target, dir, opts)
	local ok = move(self, pane, target, dir, opts)
	Shim.tern.timer(20, function() panel.resize(sized_entry.state, 90, 30, sized_entry.cx) end)
	return ok
end
sized.tab = 9
focus(sized)
assert(sized_entry.state.cols == 46, "Sizing must use the destination geometry, not the previous tab's stale width")
local resize = sized.layout.resize
sized.layout.resize = function(self, pane, dir, cells)
	return resize(self, pane, dir, cells + (if math.abs(cells) > 2 then (if cells < 0 then -2 else 2) else 0))
end
sized.tab = 10
focus(sized)
assert(sized_entry.state.cols == 46, "Divider rounding must converge on 46, rather than leave a narrower sidebar")
sized.layout.move = function(self, pane, target, dir, opts)
	local ok = move(self, pane, target, dir, opts)
	panel.resize(sized_entry.state, 45, 30, sized_entry.cx)
	return ok
end
sized.layout.resize = function(self, pane, dir, cells)
	local whole = math.modf(cells)
	if whole == 0 then return false end
	if sized_entry.state.cols == 45 and whole == 1 then whole = 2 end
	return resize(self, pane, dir, whole)
end
sized.tab = 11
focus(sized)
assert(sized_entry.state.cols == 46, "A one-column correction must not disappear when the native API uses whole cells")
print("sidebar default width is 46 terminal columns without overriding manual resizing")

-- The native close button is a visibility choice, not a missing pane to recreate.
local dismissed = Shim.window_cx()
Shim.cx = dismissed
Shim.kv.sidebar, Shim.kv.surface = false, nil
Shim.commands.sidebar.run(dismissed)
Shim.settle()
local dismissed_id = next(dismissed.native_panes)
dismissed.native_panes[dismissed_id] = nil
for _, handler in Shim.handlers.pane_closed or {} do handler({ pane = dismissed_id }, dismissed) end
focus(dismissed)
assert(next(dismissed.native_panes) == nil and Shim.kv.sidebar == false,
	"Closing the sidebar block must keep it closed instead of recreating it")
Shim.commands.sidebar.run(dismissed)
Shim.settle()
assert(next(dismissed.native_panes) ~= nil and Shim.kv.sidebar == true,
	"An explicit toggle must reopen a manually closed sidebar")

local parked = Shim.window_cx()
Shim.cx = parked
Shim.kv.sidebar, Shim.kv.surface = false, nil
Shim.commands.sidebar.run(parked)
Shim.settle()
local parked_id = next(parked.native_panes)
parked.layout:park(parked_id)
focus(parked)
assert(parked.native_panes[parked_id].info.parked and Shim.kv.sidebar == false,
	"Manually parking the sidebar must not make focus reconciliation unpark it")

local tab_closed = Shim.window_cx()
Shim.cx = tab_closed
Shim.kv.sidebar, Shim.kv.surface = false, nil
Shim.commands.sidebar.run(tab_closed)
Shim.settle()
local lost_id = next(tab_closed.native_panes)
tab_closed.native_panes[lost_id] = nil
tab_closed.tab = 8
tab_closed.session.tabs = function() return { { id = 8, session = 1 } } end
tab_closed.session.layout = function() return { root = { pane = 1 } } end
for _, handler in Shim.handlers.pane_closed or {} do handler({ pane = lost_id }, tab_closed) end
focus(tab_closed)
assert(next(tab_closed.native_panes) ~= nil and Shim.kv.sidebar == true,
	"Closing a whole tab must keep the enabled sidebar following the remaining tab")
print("native close and park remain hidden; closing a tab retains sidebar following")
