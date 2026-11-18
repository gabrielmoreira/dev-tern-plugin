--!nonstrict
-- Boundary regressions for workspace routing. Run: lune run test/ux.luau
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Store = Shim.load(base .. "/store.luau")
local s = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end })
s.workspaces = {
	{ name = "upper", path = "/home/u/Task", mountCount = 1 },
	{ name = "lower", path = "/home/u/task", mountCount = 1 },
	{ name = "windows", path = "C:\\dev\\ws\\win", mountCount = 1 },
}
assert(Store.locate(s, "/home/u/task/src").name == "lower", "POSIX path case must remain distinct")
assert(Store.locate(s, "/home/u/TASK") == nil, "POSIX path case must not be folded")
assert(Store.locate(s, "c:/DEV/ws/WIN/src").name == "windows", "Windows paths must match case-insensitively")
assert(Store.locate(s, "C:/dev/ws/winner") == nil, "Workspace path must end at a directory boundary")
assert(Store.locate(s, "") == nil, "Unknown cwd must not resolve a workspace")
print("workspace path routing passed")

local View = Shim.load(base .. "/view.luau")

local function new_state()
	local state = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end })
	state.pages = state.pages or { home = 1, mirrors = 1, prs = 1, wis = 1 }
	return state
end

-- Rendered workspace row keys, top to bottom, and where the fixed chrome sits in the tree.
local function render_walk(state, opts)
	local main = View.render(state, opts or {})
	local rows, scrolled, body_roles, fixed = {}, {}, 0, {}
	local function walk(node, inside_body, depth)
		if type(node) ~= "table" then return end
		local p = node.p or {}
		local key = p.key
		if type(key) == "string" and string.sub(key, 1, 3) == "ws:" then table.insert(rows, string.sub(key, 4)) end
		if p.role == "devcli.body" then body_roles += 1 end
		if p.role == "devcli.header" or key == "f_filter" then
			local id = p.role or key
			if inside_body then scrolled[id] = true else fixed[id] = depth end
		end
		for _, child in node.c or {} do walk(child, inside_body or p.role == "devcli.body", depth + 1) end
	end
	walk(main, false, 0)
	return rows, { main = main, body_roles = body_roles, scrolled = scrolled, fixed = fixed }
end

local function inventory(count)
	local out = {}
	for i = 1, count do
		out[i] = {
			name = string.format("ws-%03d", i),
			path = string.format("/w/ws-%03d", i),
			description = if i == 80 then "ledger migration" else "",
			mountCount = if i % 7 == 0 then 0 else 1,
		}
	end
	return out
end

local home = new_state()
home.workspaces = inventory(120)
local seen = {}
for page = 1, 3 do
	home.pages.home = page
	for _, name in View.order(home) do
		assert(not seen[name], "A workspace must appear on exactly one page")
		seen[name] = true
	end
end
for _, w in home.workspaces do assert(seen[w.name], "Every workspace, including empty ones, must be reachable by paging: " .. w.name) end

home.pages.home = 1
local before = View.order(home)
assert(#before == 50, "A presentation page holds 50 rows")
home.status["ws-009"] = { data = { mounts = { { state = "diverged" } } } }
home.status["ws-014"] = { error = { code = "X", message = "m" } }
home.status["ws-020"] = { data = { mounts = { { state = "dirty" } } } }
local after = View.order(home)
assert(table.concat(after, ",") == table.concat(before, ","), "A status change must not move a workspace row")

for _, page in { 1, 2, 3, 99 } do
	home.pages.home = page
	local rows = render_walk(home, {})
	local order = View.order(home)
	assert(#rows > 0 and table.concat(rows, ",") == table.concat(order, ","), "Keyboard order must equal the rendered rows on page " .. page)
end

home.pages.home = 1
home.filter = "ledger"
assert(#View.filtered(home, "home") == 1 and View.filtered(home, "home")[1].name == "ws-080", "Search must reach a workspace beyond the first 50")
assert(table.concat(View.order(home), ",") == "ws-080", "The matching row on a filtered page must be the keyboard target")
assert(table.concat((render_walk(home, {})), ",") == "ws-080", "The matching row must be rendered")
home.filter = "absent"
assert(#View.order(home) == 0 and #View.filtered(home, "home") == 0, "No matches must not leave stale keyboard targets")
print("workspace pages and stable order passed")

local chrome = new_state()
chrome.workspaces = inventory(3)
local _, tree = render_walk(chrome, { filter = { k = "input", p = { key = "f_filter" } } })
assert(tree.body_roles == 1, "Exactly one region scrolls")
assert(tree.fixed["devcli.header"] ~= nil and tree.fixed["f_filter"] ~= nil, "Toolbar and filter must stay outside the scrolling body")
assert(next(tree.scrolled) == nil, "Toolbar and filter must not scroll with the inventory")
local direct = false
for _, child in tree.main.c or {} do if child.p and child.p.key == "f_filter" then direct = true end end
assert(direct and tree.main.p.key == "root", "The native filter stays a direct child of the root")
print("fixed chrome passed")

local prs = new_state()
prs.screen = "prs"
prs.prs = {}
for i = 1, 70 do
	prs.prs[i] = { id = i, title = "change " .. i, repository = "repo-" .. i, author = "Ana", sourceBranch = "feature/x" .. i, targetBranch = "main" }
end
prs.prs[66].author = "Zeferino"
prs.filter = "zeferino"
assert(#View.filtered(prs, "prs") == 1 and View.filtered(prs, "prs")[1].id == 66, "PR search must reach the full inventory by author")
prs.filter = "feature/x68"
assert(#View.filtered(prs, "prs") == 1 and View.filtered(prs, "prs")[1].id == 68, "PR search must match source branches")
local mirrors = new_state()
mirrors.mirrors = {}
for i = 1, 60 do mirrors.mirrors[i] = { name = "m" .. i, branch = "main", path = "/mirrors/library-" .. i, isClean = true } end
mirrors.filter = "library-57"
assert(#View.filtered(mirrors, "mirrors") == 1 and View.filtered(mirrors, "mirrors")[1].name == "m57", "Mirror search must match the checked-out path")
print("collection search passed")

local function collect(node, out)
	out = out or { actions = {}, md = {}, kinds = {} }
	if type(node) ~= "table" then return out end
	local p = node.p or {}
	if p.actions and p.actions.click then out.actions[p.actions.click] = true end
	if node.k == "md" then table.insert(out.md, p.text) end
	out.kinds[node.k] = true
	for _, child in node.c or {} do collect(child, out) end
	return out
end

local detail = new_state()
detail.workspaces = { { name = "task", path = "/w/task", mountCount = 1 } }
detail.screen, detail.selected = "ws", "task"
detail.files = {
	task = {
		root = "/w/task",
		open = { ["/w/task/src"] = true },
		dirs = {
			["/w/task"] = { entries = {
				{ name = "src", path = "/w/task/src", directory = true },
				{ name = "vendor", path = "/w/task/vendor", directory = true },
				{ name = "README.md", path = "/w/task/README.md", directory = false },
			} },
			["/w/task/src"] = { entries = { { name = "main.lua", path = "/w/task/src/main.lua", directory = false } } },
		},
		manifest = { text = "---\nversion: 1\nname: task\n---\n\n# Context\nShip the ledger.\n" .. string.rep("Context line.\n", 1000) .. "End of workspace notes.\n" },
		activity = {},
	},
}
local overview = collect((View.render(detail, {})))
assert(overview.actions["ws.tab=repositories"] and overview.actions["ws.tab=files"] and overview.actions["ws.tab=overview"], "Every workspace tab must be reachable from the overview")
assert(not overview.actions["files.toggle=/w/task/src"] and overview.kinds.md, "Overview shows Markdown notes, while file navigation stays in Files")
local main_tree = View.render(detail, {})
local fixed_chrome = {}
for _, child in main_tree.c or {} do
	if child.p and (child.p.role == "devcli.workspace-actions" or child.p.role == "devcli.workspace-tabs") then fixed_chrome[child.p.role] = true end
end
assert(fixed_chrome["devcli.workspace-actions"] and fixed_chrome["devcli.workspace-tabs"], "The workspace action bar and tabs sit outside the scrolling body")
local opened = collect((View.render(detail, {})))
local notes = table.concat(opened.md, "\n")
assert(string.find(notes, "Ship the ledger", 1, true) and string.find(notes, "End of workspace notes.", 1, true) and not string.find(notes, "version: 1", 1, true), "Overview keeps the complete notes body and drops YAML front matter")
detail.workspace_tabs = { task = "files" }
local seen_ws = collect((View.render(detail, {})))
assert(seen_ws.actions["files.toggle=/w/task/src"] and seen_ws.actions["files.toggle=/w/task/vendor"], "Folders must be openable and closable")
assert(seen_ws.actions["files.open=/w/task/README.md"] and seen_ws.actions["files.open=/w/task/src/main.lua"], "Files in the root and in an opened folder must open")
assert(not seen_ws.actions["files.open=/w/task/vendor/x.lua"] and not seen_ws.kinds.md, "Collapsed folders draw nothing, and the Files tab carries no notes")

local browse = new_state()
browse.mirrors = { { name = "lib", branch = "main", path = "/mirrors/lib", isClean = true } }
browse.screen = "mirrors"
local listing = collect((View.render(browse, {})))
assert(listing.actions["mirror.browse=lib"] and listing.actions["mirror.sync=lib"] and listing.actions["git=/mirrors/lib"], "Browse, sync and Git are separate mirror actions")
browse.screen = "mirror"
browse.browse = { root = "/mirrors/lib", open = {}, dirs = { ["/mirrors/lib"] = { entries = { { name = "src", path = "/mirrors/lib/src", directory = true } } } }, activity = {} }
local code = collect((View.render(browse, {})))
assert(code.actions["files.toggle=/mirrors/lib/src"], "The mirror's real code tree must be directly navigable")
print("workspace files and mirror browse passed")

local big = new_state()
big.workspaces = { { name = "task", path = "/w/task", mountCount = 0 } }
big.screen, big.selected = "ws", "task"
big.workspace_tabs = { task = "files" }
-- The data layer keeps only the current page of the sorted listing, plus the total and where the page starts.
local function listing(page)
	local out = {}
	for i = (page - 1) * 100 + 1, math.min(250, page * 100) do
		out[#out + 1] = { name = string.format("f%03d.txt", i), path = string.format("/w/task/f%03d.txt", i), directory = false }
	end
	return { entries = out, total = 250, offset = (page - 1) * 100 }
end
big.files = { task = { root = "/w/task", open = {}, dirs = { ["/w/task"] = listing(1) }, pages = {} } }
local first_page = collect((View.render(big, {})))
assert(first_page.actions["files.open=/w/task/f001.txt"] and not first_page.actions["files.open=/w/task/f250.txt"], "A large folder draws one page")
assert(first_page.actions["files.page=/w/task:2"], "A large folder offers its next page")
big.files.task.pages["/w/task"] = 3
big.files.task.dirs["/w/task"] = listing(3)
local last_page = collect((View.render(big, {})))
assert(last_page.actions["files.open=/w/task/f250.txt"] and not last_page.actions["files.open=/w/task/f001.txt"], "Every entry is reachable by paging")
assert(last_page.actions["files.page=/w/task:2"], "The last page offers the previous page")

print("large folder paging passed")

local answer
s.dev.work_items = function(_, done)
	answer = done
end
Store.load_wis(s, nil, false)
s.active_root = "/new-root" -- the root changed while the provider was still reading the old one
s.wis = nil
answer({ ok = true, value = { { id = 123, title = "old root" } } }, nil)
assert(s.wis == nil, "An old-root work-item response must not populate the selected root")
print("provider root isolation passed")

Shim.load(base .. "/lenses.luau")
local lens = Shim.lenses.dev
local function capture(args, lines, status)
	local state = lens.open({ args = args }, {})
	for _, line in lines do
		lens.line(state, { text = line, links = {} })
	end
	lens.finish(state, status or 0)
	return lens.view(state)
end
local statusLines = {
	"Workspace: task",
	"Path:      /dev/ws/task",
	"Status:    differs from your workspace plan",
	"Mounts:",
	"  ○ lib [dirty]",
	"      Repository: https://example.invalid/lib",
	"      Planned: branch main",
	"      Checked out: branch=main commit=12345678",
}
assert(capture({ "ws", "status", "task", "--offline" }, statusLines) ~= nil, "Status lens must accept the offline flag")
assert(capture({ "ws", "status", "task", "--json" }, statusLines) == nil, "JSON output must remain raw")
assert(capture({ "ws", "status", "task" }, statusLines, 1) == nil, "Failed commands must retain diagnostics as raw output")
print("terminal lens boundaries passed")

local removals = {}
local guarded = Store.new({
	surface = "block",
	dev = {
		describe = function() return "dev ws remove lib --ws task" end,
		remove = function(input, done)
			table.insert(removals, input)
			done({ ok = false, error = { code = "TEST_REFUSAL", message = "No test removal is allowed", details = {} } }, nil)
		end,
	},
	redraw = function() end,
	effect = function() end,
})
guarded.active_root = "/root-one"
guarded.status.task = { data = { mounts = { { path = "lib", state = "clean", observed = { exists = true, isDirty = false } } } } }
Store.dispatch(guarded, nil, "remove.all", "task")
assert(guarded.confirm ~= nil, "Batch must first ask for confirmation")
-- Another surface can update the root and refresh this store while this confirmation is still open.
guarded.active_root = "/root-two"
Store.dispatch(guarded, nil, "confirm.yes")
assert(#removals == 0, "A root switch after review must invalidate destructive confirmation")
assert(guarded.confirm == nil, "A stale destructive confirmation must not remain actionable")
print("batch confirmation root isolation passed")
