--!nonstrict
-- Navigator data contract: lazy workspace/mirror file browsing through the dev port (paged directory reads,
-- manifest), root and browser lifetimes, selected-only status loading, activity signals, modal state, stable
-- order and the full PR collection. Store tests run against a fake port over a virtual tree, so every read is
-- observable and can be held; the real inline Bun helper is exercised on a scratch directory at the end.
-- Every dev operation answers only when the test says so (see state-reliability.luau).
-- Run from the plugin root: lune run test/navigator-data.luau
local process = require("@lune/process")
local fs = require("@lune/fs")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
base = string.gsub(base, "/$", "")
local Store = Shim.load(base .. "/store.luau")
local Dev = Shim.load(base .. "/devcli.luau")
local failures = {}
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then
		print("PASS " .. name)
	else
		table.insert(failures, name)
		print("FAIL " .. name .. ": " .. tostring(why))
	end
end

Shim.tern.timer = function(_, _)
	return { cancel = function() end }
end

-- A virtual tree: directory path -> entry names.
local dirs, files = {}, {}
local function add_dir(path: string)
	if dirs[path] then return end
	dirs[path] = {}
	local parent, name = string.match(path, "^(.*)/([^/]+)$")
	if parent and parent ~= "" then
		add_dir(parent)
		table.insert(dirs[parent], name)
	end
end
local function add_file(path: string, text: string?)
	local parent, name = string.match(path, "^(.*)/([^/]+)$")
	add_dir(parent)
	files[path] = text or ""
	table.insert(dirs[parent], name)
end

add_file("/a/ws/task/ws.md", "# Plan\n\nBody text.\n")
add_file("/a/ws/task/notes.txt", "n")
add_file("/a/ws/task/lib/a.lua")
add_file("/a/ws/task/lib/src/deep.lua")
add_file("/a/ws/task/lib/src/nested/leaf.lua")
add_file("/a/ws/task/docs/guide.md")
for i = 1, 1200 do
	add_file(string.format("/a/ws/task/big/f%04d.txt", i))
end
add_file("/a/ws/task/big/zdir/inside.txt")
add_file("/a/ws/empty/ws.md", "")
add_file("/b/ws/task/other.txt")
add_file("/a/mirrors/repo/README.md")
add_file("/a/mirrors/repo/src/main.lua")
add_file("/a/mirrors/repo/src/deeper/x.lua")

-- What DevCli.read_dir answers: the whole directory sorted (directories first, then name without case), then one
-- page of 100, the offset clamped to the last page.
local function serve(path, offset)
	if not dirs[path] then
		return { ok = false, error = { code = "ENOENT", message = "no such directory: " .. path, details = {} } }
	end
	local entries = {}
	for _, name in dirs[path] do
		local full = path .. "/" .. name
		table.insert(entries, { name = name, path = full, directory = dirs[full] ~= nil, modifiedAt = 1700000000 })
	end
	table.sort(entries, function(a, b)
		if a.directory ~= b.directory then return a.directory end
		local la, lb = string.lower(a.name), string.lower(b.name)
		if la ~= lb then return la < lb end
		return a.name < b.name
	end)
	local total = #entries
	local off = offset
	if off >= total then off = if total > 0 then ((total - 1) // 100) * 100 else 0 end
	local page = {}
	for i = off + 1, math.min(off + 100, total) do table.insert(page, entries[i]) end
	return { ok = true, value = { entries = page, total = total, offset = off } }
end

local reads = {}
local function read_paths()
	local out = {}
	for _, r in reads do out[r.path] = (out[r.path] or 0) + 1 end
	return out
end

local function new_dev()
	local dev = { calls = {}, hold = false }
	function dev.describe(op)
		return op
	end
	function dev.folders()
		return {}
	end
	function dev.git_folder() end
	function dev.read_dir(path, offset, done)
		local call = { path = path, offset = offset, done = done }
		table.insert(reads, call)
		if not dev.hold then
			call.answered = true
			done(serve(path, offset), nil)
		end
	end
	function dev.manifest(path, done)
		local text = files[path .. "/ws.md"]
		if text == nil then
			return done({ ok = false, error = { code = "ENOENT", message = "ws.md does not exist in this workspace.", details = {} } }, nil)
		end
		done({ ok = true, value = { text = text, modifiedAt = 1800000000 } }, nil)
	end
	return setmetatable(dev, {
		__index = function(_, op)
			return function(input, done)
				table.insert(dev.calls, { op = op, input = input, done = done })
			end
		end,
	})
end
local function calls_of(dev, op)
	local out = {}
	for _, c in dev.calls do
		if c.op == op then table.insert(out, c) end
	end
	return out
end
local function latest(dev, op)
	local all = calls_of(dev, op)
	local c = all[#all]
	assert(c ~= nil and not c.answered, "no unanswered " .. op .. " call")
	return c
end
local function answer(call, value)
	assert(not call.answered, "call answered twice")
	call.answered = true
	call.done({ ok = true, value = value }, nil)
end
local function answer_read(call)
	assert(not call.answered, "read answered twice")
	call.answered = true
	call.done(serve(call.path, call.offset), nil)
end

local effects
local function store(dev)
	Shim.kv.root = nil
	effects = {}
	table.clear(reads)
	return Store.new({
		surface = "block",
		dev = dev,
		redraw = function() end,
		effect = function(_, kind, data)
			table.insert(effects, { kind = kind, data = data })
		end,
	})
end

local function workspaces(root)
	return {
		{ name = "task", path = root .. "/ws/task", mountCount = 1, lastUsedAt = "2026-01-02T03:04:05.000Z", createdAt = "2025-12-31T00:00:00Z" },
		{ name = "empty", path = root .. "/ws/empty", mountCount = 0, createdAt = "2026-01-01T00:00:00Z" },
		{ name = "Zeta", path = root .. "/ws/zeta", mountCount = 2, lastUsedAt = "2030-01-01T00:00:00Z" },
	}
end
local function in_root(dev, root)
	local s = store(dev)
	s.active_root = root
	s.workspaces = workspaces(root)
	return s
end
local function settle_refresh(dev, root, ws_list, mirrors)
	answer(latest(dev, "roots"), { { path = root } })
	answer(latest(dev, "current"), { root = root, source = "default" })
	answer(latest(dev, "workspaces"), ws_list or workspaces(root))
	answer(latest(dev, "mirrors"), mirrors or {})
end
local function root_dir(s, name)
	local b = s.files[name]
	assert(b ~= nil, "no browser for " .. name)
	return b.dirs[b.root]
end
local function names_of(dir)
	local out = {}
	for _, e in dir.entries do table.insert(out, e.name) end
	return out
end

test("selecting a workspace reads only its root page, with the manifest and file activity", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	local b = s.files.task
	assert(b and b.root == "/a/ws/task", "the selected workspace must own a browser rooted at its folder")
	local dir = root_dir(s, "task")
	local names = names_of(dir)
	assert(table.concat(names, ",") == "big,docs,lib,notes.txt,ws.md", "directories first, then files by name: " .. table.concat(names, ","))
	assert(dir.entries[1].directory == true and dir.entries[4].directory == false and dir.total == 5 and dir.offset == 0, "entry kinds and counts come from the port")
	assert(dir.entries[3].path == "/a/ws/task/lib" and dir.entries[3].modifiedAt == 1700000000, "entries carry absolute paths and modification times")
	assert(b.open["/a/ws/task"] == true, "the root directory is shown open")
	local seen = read_paths()
	local count = 0
	for _ in seen do count += 1 end
	assert(seen["/a/ws/task"] == 1 and count == 1, "only the root is read; collapsed children are never touched")
	assert(string.find(b.manifest.text, "# Plan", 1, true) ~= nil and b.manifest.modifiedAt == 1800000000, "the manifest body and its time are kept")
	local signals = {}
	for _, a in b.activity do signals[a.kind] = a.modifiedAt end
	assert(signals.used and signals.created and signals.used > signals.created, "dev's recorded use and creation stay named signals")
	assert(signals.file == 1800000000, "a modification time read from the file system is a `file` signal")
	assert(b.activity[1].modifiedAt >= b.activity[#b.activity].modifiedAt, "activity is newest first")
end)

test("a workspace without mounts still gets its browser when clicked", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "empty")
	assert(s.files.empty ~= nil and #root_dir(s, "empty").entries == 1, "the empty workspace's root must be listed")
	assert(#calls_of(dev, "status") == 0, "no status read for a workspace without mounts")
end)

test("only expanded directories are read", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	table.clear(reads)
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/lib")
	local b = s.files.task
	assert(b.open["/a/ws/task/lib"] == true, "toggle expands")
	assert(table.concat(names_of(b.dirs["/a/ws/task/lib"]), ",") == "src,a.lua", "lib lists its entries")
	assert(#reads == 1 and reads[1].path == "/a/ws/task/lib", "exactly the expanded directory is read")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/lib")
	assert(b.open["/a/ws/task/lib"] == false and #reads == 1, "collapse reads nothing")
	Store.dispatch(s, nil, "files.toggle", "/etc")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/notes.txt")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/lib/src")
	assert(#reads == 1 and b.open["/etc"] == nil and b.open["/a/ws/task/notes.txt"] == nil, "outside, file and unlisted paths are ignored")
end)

test("a large directory is read one page at a time and every page stays reachable", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/big")
	local dir = s.files.task.dirs["/a/ws/task/big"]
	assert(dir.total == 1201 and #dir.entries == 100 and dir.offset == 0 and dir.entries[1].name == "zdir", "the first page is 100 of 1201, sorted over the whole directory")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:13")
	dir = s.files.task.dirs["/a/ws/task/big"]
	assert(#dir.entries == 1 and dir.entries[1].name == "f1200.txt" and dir.offset == 1200, "the last page holds the rest")
	assert(s.files.task.pages["/a/ws/task/big"] == 13, "the page is kept per directory")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:99")
	assert(s.files.task.dirs["/a/ws/task/big"].offset == 1200 and s.files.task.pages["/a/ws/task/big"] == 13, "a page past the end clamps to the last")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:2")
	dir = s.files.task.dirs["/a/ws/task/big"]
	assert(dir.entries[1].name == "f0100.txt", "page two follows page one without gaps: " .. dir.entries[1].name)
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:1")
	assert(s.files.task.pages["/a/ws/task/big"] == nil and s.files.task.dirs["/a/ws/task/big"].entries[1].name == "zdir", "page one is the default")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/notes.txt:2")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/lib:2")
	assert(#reads == 6, "closed or non-directory paths request nothing: " .. #reads)
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/big")
	assert(s.files.task.pages["/a/ws/task/big"] == nil, "collapsing forgets the page")
end)

test("the page on screen stays until its answer, and a late answer cannot replace a newer page", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/big")
	dev.hold = true
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:2")
	local second = reads[#reads]
	local shown = s.files.task.dirs["/a/ws/task/big"]
	assert(shown.loading and shown.entries[1].name == "zdir", "page one stays shown while page two loads")
	Store.dispatch(s, nil, "files.page", "/a/ws/task/big:3")
	local third = reads[#reads]
	answer_read(third)
	answer_read(second)
	local dir = s.files.task.dirs["/a/ws/task/big"]
	assert(dir.offset == 200 and not dir.loading and s.files.task.pages["/a/ws/task/big"] == 3, "the older request's answer is dropped")
end)

test("a failing read is shown as an error without losing the page", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	dev.read_dir = function(_, _, done)
		done({ ok = false, error = { code = "BUN_MISSING", message = "Bun was not found.", nextStep = "Install Bun.", details = {} } }, nil)
	end
	Store.dispatch(s, nil, "ws", "task")
	local dir = root_dir(s, "task")
	assert(#dir.entries == 0 and dir.error == "Bun was not found. Install Bun." and not dir.loading, "the actionable error is kept for the view")
end)

test("opening a file edits it; directories and unknown paths do not", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	Store.dispatch(s, nil, "files.open", "/a/ws/task/notes.txt")
	Store.dispatch(s, nil, "files.open", "/a/ws/task/lib")
	Store.dispatch(s, nil, "files.open", "/a/ws/task/missing.txt")
	Store.dispatch(s, nil, "files.open", "/etc/passwd")
	assert(#effects == 1 and effects[1].kind == "edit" and effects[1].data.path == "/a/ws/task/notes.txt", "only the listed file opens")
end)

test("status and folders load for the selected workspace only, and rows keep one stable name order", function()
	local dev = new_dev()
	local s = store(dev)
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	local order = {}
	for _, w in s.workspaces do table.insert(order, w.name) end
	assert(table.concat(order, ",") == "empty,task,Zeta", "case-insensitive name order, not recency: " .. table.concat(order, ","))
	assert(#calls_of(dev, "status") == 0, "no workspace is read before one is selected")
	Store.dispatch(s, nil, "ws", "task")
	assert(#calls_of(dev, "status") == 1 and latest(dev, "status").input.ws == "task", "the selected workspace is read")
	answer(latest(dev, "status"), { mounts = {} })
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	assert(#calls_of(dev, "status") == 2, "a refresh re-reads only the selected workspace")
	assert(s.status.Zeta == nil, "other workspaces are not scanned")
	assert(s.files.task ~= nil, "the selected browser survives a refresh of the same root")
end)

test("the newest commit of each mount is an activity signal of the current browser only", function()
	local dev = new_dev()
	local s = store(dev)
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	answer(latest(dev, "status"), { mounts = { { path = "lib", state = "clean" } } })
	local commit = latest(dev, "last_commit")
	assert(commit.input == "/a/ws/task/lib", "the mount's repository is asked: " .. tostring(commit.input))
	local old = commit
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	old.answered = true
	old.done(1790000000, nil)
	for _, a in s.files.task.activity do
		assert(a.kind ~= "commit", "an answer for a replaced browser must not land")
	end
	answer(latest(dev, "status"), { mounts = { { path = "lib", state = "clean" } } })
	-- dev stubs record port calls as (input, done); this one answers the commit read of the live browser
	local live = latest(dev, "last_commit")
	live.answered = true
	live.done(1790000000, nil)
	local found
	for _, a in s.files.task.activity do
		if a.kind == "commit" then found = a end
	end
	assert(found and found.modifiedAt == 1790000000 and found.name == "Last commit in lib", "the commit time is labelled as the last commit")
end)

test("a refresh reloads expanded directories and drops what is gone", function()
	local dev = new_dev()
	local s = store(dev)
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/docs")
	add_file("/a/ws/task/docs/new.md")
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a")
	local dir = s.files.task.dirs["/a/ws/task/docs"]
	assert(s.files.task.open["/a/ws/task/docs"] and dir and #dir.entries == 2, "the expanded directory is read again")
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a", { workspaces("/a")[2] })
	assert(s.files.task == nil, "a browser whose workspace vanished is dropped")
end)

test("a root change clears browsers and late answers cannot enter the new root", function()
	local dev = new_dev()
	local s = store(dev)
	Store.dispatch(s, nil, "refresh")
	settle_refresh(dev, "/a", nil, { { name = "repo", path = "/a/mirrors/repo", linked = true, branch = "main" } })
	dev.hold = true
	Store.dispatch(s, nil, "ws", "task")
	local late_dir = reads[#reads]
	Store.dispatch(s, nil, "mirrors", nil)
	Store.dispatch(s, nil, "mirror.browse", "repo")
	local late_mirror = reads[#reads]
	local late_status = latest(dev, "status")
	Store.dispatch(s, nil, "root", "/b")
	assert(next(s.files) == nil and s.browse == nil, "browsers belong to one root")
	assert(s.pages.home == 1, "pages restart with the root")
	settle_refresh(dev, "/b")
	answer_read(late_dir)
	answer_read(late_mirror)
	answer(late_status, { mounts = { { path = "stale", state = "dirty" } } })
	assert(next(s.files) == nil and s.browse == nil and s.status.task == nil, "answers started in the old root land nowhere")
	table.clear(reads)
	Store.dispatch(s, nil, "files.toggle", "/a/ws/task/lib")
	assert(#reads == 0 and next(s.files) == nil, "an old-root path cannot be browsed")
	dev.hold = false
	Store.dispatch(s, nil, "ws", "task")
	assert(s.files.task.root == "/b/ws/task" and #root_dir(s, "task").entries == 1, "the same name in the new root browses the new folder")
end)

test("mirror.browse opens the mirror's own checkout and expands lazily", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	s.mirrors = { { name = "repo", path = "/a/mirrors/repo", linked = false, branch = "unknown" } }
	Store.dispatch(s, nil, "mirror.browse", "repo")
	assert(s.screen == "mirror" and s.browse.root == "/a/mirrors/repo", "the mirror's real path is browsed")
	assert(table.concat(names_of(s.browse.dirs["/a/mirrors/repo"]), ",") == "src,README.md", "entries come from the checkout")
	assert(#reads == 1, "collapsed subtrees stay unread")
	Store.dispatch(s, nil, "files.toggle", "/a/mirrors/repo/src")
	assert(s.browse.dirs["/a/mirrors/repo/src"] ~= nil, "expanding reads that directory")
	for _, r in reads do
		assert(string.find(r.path, ".dev/repos", 1, true) == nil, "git administration folders are not a substitute")
	end
	assert(#calls_of(dev, "sync_mirrors") == 0, "browsing never synchronizes")
	Store.dispatch(s, nil, "mirror.browse", "ghost")
	assert(s.browse.name == "repo", "an unknown mirror changes nothing")
	Store.dispatch(s, nil, "back", nil)
	assert(s.browse == nil and s.screen == "mirrors", "back leaves the mirror and drops its browser")
end)

test("create and add use a modal that cancels without touching the background", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "ws", "task")
	s.filter = "ta"
	Store.dispatch(s, nil, "create", nil)
	assert(s.modal == "create" and s.screen == "ws" and s.selected == "task" and s.filter == "ta", "create opens over the current screen")
	Store.dispatch(s, nil, "modal.close", nil)
	assert(s.modal == nil and s.modal_ws == nil and s.screen == "ws" and s.selected == "task" and s.filter == "ta", "cancel leaves everything as it was")
	Store.dispatch(s, nil, "add", "empty")
	assert(s.modal == "add" and s.modal_ws == "empty" and s.selected == "task" and s.screen == "ws", "add names its workspace without navigating")
	Store.dispatch(s, nil, "modal.close", nil)
end)

test("a successful creation closes its modal and selects the result; a late one cannot close a newer dialog", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "create", nil)
	Store.preview_workspace(s, nil, { source = "empty", name = "fresh" })
	answer(latest(dev, "create_plan"), { name = "fresh", path = "/a/ws/fresh", exists = false, mounts = {} })
	Store.commit_workspace(s, nil)
	answer(latest(dev, "create"), { name = "fresh", created = true })
	assert(s.modal == nil, "success closes the dialog")
	settle_refresh(dev, "/a", { { name = "fresh", path = "/a/ws/fresh", mountCount = 0 } })
	assert(s.selected == "fresh" and s.screen == "ws", "the new workspace is selected")
	Store.dispatch(s, nil, "create", nil)
	Store.preview_workspace(s, nil, { source = "empty", name = "second" })
	answer(latest(dev, "create_plan"), { name = "second", path = "/a/ws/second", exists = false, mounts = {} })
	Store.commit_workspace(s, nil)
	Store.dispatch(s, nil, "modal.close", nil)
	Store.dispatch(s, nil, "add", "fresh")
	answer(latest(dev, "create"), { name = "second", created = true })
	assert(s.modal == "add" and s.modal_ws == "fresh", "an answer for a dismissed dialog must not close another one")
end)

test("a mounted repository closes the add modal and keeps the workspace selected", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	Store.dispatch(s, nil, "add", "task")
	Store.add_repo(s, nil, "task", { repo = "https://example.invalid/r.git" })
	answer(latest(dev, "add"), {})
	assert(s.modal == nil and s.modal_ws == nil and s.selected == "task", "success closes and selects")
end)

test("pages are per collection and positive", function()
	local dev = new_dev()
	local s = in_root(dev, "/a")
	assert(s.pages.home == 1 and s.pages.mirrors == 1 and s.pages.prs == 1 and s.pages.wis == 1, "every collection starts on page one")
	Store.dispatch(s, nil, "page", "prs:3")
	Store.dispatch(s, nil, "page", "mirrors:0")
	Store.dispatch(s, nil, "page", "bogus:2")
	Store.dispatch(s, nil, "page", "home:x")
	assert(s.pages.prs == 3 and s.pages.mirrors == 1 and s.pages.home == 1 and s.pages.bogus == nil, "only a positive page of a known collection applies")
end)

test("configured mise selection fills a missing PATH without overriding explicit executables", function()
	local old_os, old_getenv, old_exists = Shim.tern.runtime.os, Shim.tern.getenv, Shim.tern.fs.exists
	local old_execution = Shim.kv.execution
	local shim = "/fixture/mise/shims/dev"
	local stale = "/fixture/mise/installs/github-gabrielmoreira-dev-cli/5.4.1/dev"
	local custom = "/fixture/custom/dev"
	local direct = "/fixture/custom/github-gabrielmoreira-dev-cli/5.4.1/dev"
	local environment = { HOME = "/fixture/home", MISE_DATA_DIR = "/fixture/mise" }
	local ok, why = pcall(function()
		Shim.tern.runtime.os = "macos"
		Shim.tern.getenv = function(key) return environment[key] end
		Shim.tern.fs.exists = function(path) return path == shim or path == stale or path == custom or path == direct end
		Shim.kv.execution = { mode = "inherited", revision = 701 }
		assert(Dev.binary({ PATH = "/fixture/custom/github-gabrielmoreira-dev-cli/5.4.1" }) == direct, "A matching directory name must not replace an explicit direct-install PATH")
		assert(Dev.binary({ PATH = "/fixture/mise/installs/github-gabrielmoreira-dev-cli/5.4.1" }) == stale, "An explicit install on PATH remains authoritative")
		assert(Dev.binary({ PATH = "/usr/bin:/bin" }) == shim, "Desktop launches without mise on PATH must honor its configured shim")
		assert(Dev.binary({ PATH = "/fixture/custom" }) == custom, "An explicit non-mise PATH must remain authoritative")
		assert(Dev.binary({ PATH = "/usr/bin", DEV_TERN_BIN = custom }) == custom, "The explicit executable override must remain authoritative")
		Shim.kv.execution = { mode = "shell", kind = "bash", shell = "/unused/bash", revision = 702 }
		assert(Dev.binary({ PATH = "/fixture/mise/installs/github-gabrielmoreira-dev-cli/5.4.1" }) == stale, "Captured shell tool selection must not be replaced by the global shim")
		assert(Dev.binary({ PATH = "/usr/bin:/bin" }) == "dev", "A captured shell without dev must not silently use an unrelated global install")
	end)
	Shim.tern.runtime.os, Shim.tern.getenv, Shim.tern.fs.exists = old_os, old_getenv, old_exists
	Shim.kv.execution = old_execution
	assert(ok, why)
end)

local function pr_payload(payload, live)
	local shell = Shim.load(base .. "/shellenv.luau")
	local resolve, run = shell.resolve, shell.run
	local result
	local ok, why = pcall(function()
		shell.resolve = function(_, done) done({ PATH = process.env.PATH }, nil, nil) end
		shell.run = function(_, _, done)
			done({ status = 0, stdout = Shim.tern.json.encode(payload), stderr = "" }, nil)
		end
		Dev.pull_requests({ root = base, live = live }, function(r) result = r end)
	end)
	shell.resolve, shell.run = resolve, run
	assert(ok, why)
	assert(result, "The PR adapter did not answer")
	return result
end

test("cached and live PR reads preserve the complete searchable collection", function()
	local rows = {}
	for id = 1, 80 do table.insert(rows, { id = id, title = "Review " .. id, repository = "sample" }) end
	for _, live in { false, true } do
		local r = pr_payload(if live then { items = rows, errors = {} } else rows, live)
		assert(r.ok and #r.value == 80 and r.value[80].id == 80, "Both CLI response shapes must retain PRs beyond the first 50")
		local s = in_root(new_dev(), "/a")
		s.prs, s.filter = r.value, "Review 80"
		local matches = Shim.load(base .. "/view.luau").filtered(s, "prs")
		assert(#matches == 1 and matches[1].id == 80, "A PR beyond the first page must remain searchable after adaptation")
	end
end)

test("partial PR provider failures retain readable PRs and expose a redacted warning", function()
	local secret = "ghp_thisIsAFakeTokenValue1234567890ab"
	local r = pr_payload({
		items = { { id = 81, title = "Available review", repository = "sample" } },
		errors = { "[unavailable] GITHUB_TOKEN=" .. secret },
	}, true)
	assert(r.ok and #r.value == 1 and r.value[1].id == 81, "One provider failure must not discard successful providers")
	assert(r.warning and not string.find(r.warning.detail, secret, 1, true), "Partial failures must be visible without disclosing printed credentials")
	local dev = new_dev()
	dev.pull_requests = function(_, done) done(r) end
	local s = in_root(dev, "/a")
	Store.load_prs(s, nil, true)
	assert(s.prs[1].id == 81 and s.prs_warning == r.warning, "The inspected collection must retain both successful PRs and the partial-read warning")
	s.screen = "prs"
	local text = {}
	local function collect(node)
		if type(node) ~= "table" then return end
		local props = node.p or {}
		if type(props.text) == "string" then table.insert(text, props.text) end
		for _, span in type(props.spans) == "table" and props.spans or {} do
			if span.t then table.insert(text, span.t) end
		end
		for _, child in node.c or {} do collect(child) end
	end
	collect(Shim.load(base .. "/view.luau").render(s, {}))
	local visible = table.concat(text, "\n")
	assert(string.find(visible, "Available review", 1, true) and string.find(visible, "[unavailable]", 1, true), "Successful PRs and the failed provider must both be visible")
	assert(not string.find(visible, secret, 1, true), "The partial-read card must not disclose a provider credential")
end)

-- The real helper, on a scratch directory under the system temp folder (read-only reads, nothing outside it).
local scratch = string.gsub(process.env.TEMP or process.env.TMPDIR or "/tmp", "\\", "/") .. "/navigator-data-" .. tostring(os.time())
local function settled(fn)
	local out
	fn(function(r) out = r end)
	Shim.settle()
	assert(out ~= nil, "the port never answered")
	return out
end

test("the Bun helper pages a directory sorted over all entries, with times for the page only", function()
	fs.writeDir(scratch)
	fs.writeDir(scratch .. "/sub")
	fs.writeFile(scratch .. "/sub/inner.txt", "x")
	fs.writeFile(scratch .. "/b.txt", "b")
	fs.writeFile(scratch .. "/A.txt", "a")
	for i = 1, 150 do fs.writeFile(string.format("%s/n%03d.txt", scratch, i), "") end
	fs.writeFile(scratch .. "/ws.md", "---\nname: x\n---\n\n# Hello\n")
	local r = settled(function(done) Dev.read_dir(scratch, 0, done) end)
	assert(r.ok, "read failed: " .. (r.error and (r.error.code .. " " .. r.error.message) or "?"))
	local v = r.value
	assert(v.total == 154 and #v.entries == 100 and v.offset == 0, "100 of 154: " .. v.total .. "/" .. #v.entries)
	assert(v.entries[1].name == "sub" and v.entries[1].directory == true, "directories first")
	assert(v.entries[2].name == "A.txt" and v.entries[3].name == "b.txt" and v.entries[4].directory == false, "then files without regard to case")
	assert(type(v.entries[1].modifiedAt) == "number" and v.entries[1].path == scratch .. "/sub", "entries carry absolute paths and times")
	local second = settled(function(done) Dev.read_dir(scratch, 100, done) end).value
	assert(#second.entries == 54 and second.offset == 100, "the second page holds the rest")
	local past = settled(function(done) Dev.read_dir(scratch, 9999, done) end).value
	assert(past.offset == 100 and #past.entries == 54, "an offset past the end clamps to the last page")
	local inside = settled(function(done) Dev.read_dir(scratch .. "/sub", 0, done) end).value
	assert(#inside.entries == 1 and inside.entries[1].name == "inner.txt" and inside.entries[1].directory == false, "a subdirectory lists its own entries")
	local gone = settled(function(done) Dev.read_dir(scratch .. "/nope", 0, done) end)
	assert(not gone.ok and gone.error.code == "ENOENT", "a missing directory is ENOENT: " .. tostring(gone.error and gone.error.code))
end)

test("the Bun helper reads the manifest body and time; a missing one is ENOENT", function()
	local r = settled(function(done) Dev.manifest(scratch, done) end)
	assert(r.ok and r.value.text == "# Hello\n" and type(r.value.modifiedAt) == "number", "body without frontmatter, with a time: " .. tostring(r.ok and r.value.text))
	local none = settled(function(done) Dev.manifest(scratch .. "/sub", done) end)
	assert(not none.ok and none.error.code == "ENOENT", "no ws.md in sub")
end)

test("a missing Bun is an actionable error, not a guessed listing", function()
	local saved_path, saved_Path = Shim.env_override.PATH, Shim.env_override.Path
	local saved_exists = Shim.tern.fs.exists
	Shim.tern.fs.exists = function(path)
		local name = string.match(path, "([^/\\]+)$")
		if name == "bun" or name == "bun.exe" then return false end
		return saved_exists(path)
	end
	Shim.env_override.PATH, Shim.env_override.Path = "/no/such/dir", "/no/such/dir"
	local ok, r = pcall(settled, function(done) Dev.read_dir(scratch, 0, done) end)
	Shim.env_override.PATH, Shim.env_override.Path = saved_path, saved_Path
	Shim.tern.fs.exists = saved_exists
	assert(ok, tostring(r))
	assert(not r.ok and r.error.code == "BUN_MISSING" and string.find(r.error.nextStep, "Install Bun", 1, true), "Bun missing must say how to fix it")
end)

pcall(fs.removeDir, scratch)

if #failures > 0 then
	error(#failures .. " navigator data regressions failed: " .. table.concat(failures, "; "))
end
print("navigator data passed")
