--!nonstrict
-- Real PR adapters and store; only provider execution is replaced.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
Shim.env_override.DEV_TERN_BIN = "fixture-dev"
local failures = 0
local function check(ok, message)
	print((if ok then "PASS " else "FAIL ") .. message)
	if not ok then failures += 1 end
end
local launched
Shim.tern.process.run = function(argv, _, done)
	launched = table.clone(argv)
	local output
	if argv[2] == "pr" and argv[3] == "view" then
		output = if argv[4] == "8"
			then [[{"id":8,"provider":"ado","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-02T10:00:00Z"}]]
			else [[{"id":7,"provider":"ado","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z"}]]
	else
		local mine = [[{"id":1,"tenant":"dev.azure.com/fixture","title":"Mine","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-01T10:00:00Z"}]]
		output = if table.find(argv, "--all") then "[" .. mine .. [[,{"id":2,"provider":"github","title":"Other author","createdAt":"2026-11-01T10:00:00Z","updatedAt":"2026-11-02T10:00:00Z"}]] .. "]" else "[" .. mine .. "]"
	end
	done({ status = 0, stdout = output, stderr = "", timed_out = false }, nil)
end
local Dev = Shim.load(base .. "/devcli.luau")
local result
Dev.pull_requests({ scope = "all", status = "open", repo = "org/repo", provider = "github", project = "alpha", ws = "feature", label = nil }, function(r) result = r end)
check(result and result.ok and #result.value == 2, "All scope includes PRs by another author")
check(result and result.ok and result.value[1].createdAt == "2026-11-01T10:00:00Z" and result.value[1].updatedAt == nil, "ADO copied creation timestamp is not presented as update")
check(table.find(launched, "--all") ~= nil and table.find(launched, "--mine") == nil, "All scope explicitly selects all authors")
for _, flag in { "--offline", "--status", "--repo", "--provider", "--project", "--ws" } do
	check(table.find(launched, flag) ~= nil, "PR query forwards " .. flag)
end
check(launched[table.find(launched, "--repo") + 1] == "org/repo", "PR repository filter reaches CLI")
Dev.pull_requests({ scope = "mine", status = "closed", label = "urgent" }, function(r) result = r end)
check(result and result.ok and #result.value == 1 and table.find(launched, "--mine") ~= nil, "Mine scope is explicit alongside filters")
check(table.find(launched, "--all") == nil and table.find(launched, "--label") ~= nil, "Mine label filter does not imply all authors")
Dev.pull_requests({ scope = "mine", status = "open", live = true }, function(r) result = r end)
check(result and result.ok and table.find(launched, "--offline") == nil, "Only live PR reads omit the offline flag")
Dev.pull_request({ ref = "https://ado.test/pr/7" }, function(r) result = r end)
check(result and result.ok and result.value.updatedAt == nil, "ADO detail does not expose copied creation time as an update")
check(result and result.ok and table.find(launched, "--offline") ~= nil, "PR detail remains cache-only")
Dev.pull_request({ ref = "8" }, function(r) result = r end)
check(result and result.ok and result.value.updatedAt == "2026-11-02T10:00:00Z", "Distinct ADO detail update timestamp is preserved")
local Store = Shim.load(base .. "/store.luau")
Shim.tern.timer = function() return { cancel = function() end } end
local calls = {}
local s = Store.new({ surface = "block", dev = { pull_requests = function(input, done) table.insert(calls, { input = input, done = done }) end }, redraw = function() end, effect = function() end })
s.active_root = "C:/fixture"
s.screen = "prs"
Store.dispatch(s, nil, "prs.scope", "all")
check(#calls == 1 and calls[1].input.scope == "all" and calls[1].input.status == "open" and not calls[1].input.live, "Scope change queries cache instead of fetching")
Store.dispatch(s, nil, "prs.query", { scope = "mine", status = "closed" })
check(#calls == 1 and s.pr_query.scope == "all", "Busy query is rejected without relabeling current results")
if #calls == 1 then
	calls[1].done({ ok = true, value = { { id = 2, title = "Other author" } } }, nil)
	check(s.prs and s.prs[1].id == 2, "Committed query results become the visible collection")
	local View = Shim.load(base .. "/view.luau")
	local tree = View.render(s, {})
	local function visible_text(node)
		if type(node) ~= "table" then return "" end
		local out = {}
		for _, span in (node.p or {}).spans or {} do table.insert(out, tostring(span.t or "")) end
		for _, child in node.c or {} do table.insert(out, visible_text(child)) end
		return table.concat(out, " ")
	end
	check(string.find(visible_text(tree), "Showing All PRs", 1, true) ~= nil, "Visible PR scope matches the committed query")
end
Store.dispatch(s, nil, "prs.filters", nil)
check(s.modal == "prsfilters", "Filter action opens the PR query modal")
Store.dispatch(s, nil, "prs.query", { scope = "all", status = "completed", provider = "github", project = "alpha", repo = "org/repo" })
check(#calls == 2 and s.prs == nil and s.pr_query.provider == "github", "New query is committed and clears old results before loading")
if #calls == 2 then
	check(calls[2].input.status == "completed" and calls[2].input.repo == "org/repo" and calls[2].input.project == "alpha", "Committed filters reach the store port")
	calls[2].done({ ok = true, value = { { id = 3, status = "completed" } } }, nil)
	check(s.prs and s.prs[1].id == 3 and s.modal == nil, "Only new query results are visible and submit closes the modal")
end
Store.dispatch(s, nil, "prs.query", { scope = "all", status = "open", label = "needs-review", ws = "feature" })
check(s.pr_query.status == "completed" and s.prs and s.prs[1].id == 3, "Invalid label/workspace combination is rejected")
Store.dispatch(s, nil, "prs.query", { scope = "all", status = "open", label = "needs-review" })
check(#calls == 3 and s.prs == nil, "Valid label query clears old cached results")
if #calls == 3 then
	s.active_root = "C:/other"
	calls[3].done({ ok = true, value = { { id = 4 } } }, nil)
	check(s.prs == nil and s.pr_query.label == "needs-review", "Late response after root change is not relabeled")
end
assert(failures == 0, tostring(failures) .. " PR query contracts failed")
print("PR query passed")
