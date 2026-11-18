--!nonstrict
-- Window observations must reach each native navigator without a CLI refresh.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Dev = Shim.load(base .. "/devcli.luau")
local function answers(value)
	return function(_, done) done({ ok = true, value = value }, nil) end
end
Dev.roots = answers({})
Dev.current = answers({ root = "/work", source = "default" })
Dev.workspaces = answers({ { name = "alpha", path = "/work/alpha", mountCount = 1 }, { name = "zulu", path = "/work/zulu", mountCount = 1 } })
Dev.mirrors = answers({})
Dev.status = answers({ mounts = {} })
Shim.load(base .. "/host.luau")
local panel = Shim.blocks.panel
local cx = { pane = 900, renders = 0, render = function(self) self.renders += 1 end, frame = function() end, open = function() end, copy = function() end, toast = function() end }
Shim.panes = { { pane = 900 } }
local state = panel.init(cx, {}, nil)
Shim.settle()
local observation = {
	available = true, complete = false, host = 0,
	sessions = { { id = 1, host = 0, name = "Review" } },
	tabs = { { id = 10, session = 1, name = "API" } },
	panes = { { pane = 100, tab = 10, kind = "terminal", cwd = "/work/zulu" } },
}
panel.event(state, { ev = "action", act = "presence.snapshot", value = Shim.tern.json.encode(observation) }, cx)
local actions = {}
local function walk(n)
	if type(n) ~= "table" then return end
	for _, action in (n.p and n.p.actions) or {} do if type(action) == "string" then actions[action] = n end end
	for _, c in n.c or {} do walk(c) end
end
walk(panel.view(state, cx).main)
assert(actions["presence=zulu"], "The native block ignored the window observation instead of exposing the open workspace")
assert(cx.renders > 0, "A new presence snapshot must repaint the actual native navigator")
print("PASS window presence snapshots reach native workspace rows")
panel.event(state, { ev = "action", act = "presence.snapshot", value = "invalid JSON" }, cx)
local Store = Shim.load(base .. "/store.luau")
assert(Store.presence_for(state.store, state.store.workspaces[2]) == nil, "An invalid observation must not leave stale positive presence")
print("PASS malformed native observations become unknown, not stale positive presence")
process.exit(0)
