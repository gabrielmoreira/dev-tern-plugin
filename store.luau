--!nonstrict
-- State and actions shared by the sidebar (window half) and the palette block (host half). dev is reached only
-- through the port in `env.dev` (operations by name, see devcli.luau); each surface also gives how to redraw
-- and how to reach window-only effects (open a session, open git, copy). The root picked in the UI lives in
-- tern.kv, which both halves and every window share.

local Remedies = require("./remedies")
local Store = {}

local snapshot
local fail
local STATUS_GAP_MS = 60
local FILE_PAGE = 100 -- entries per page of a directory; the dev port pages with the same size
local INSPECT_MAX_AGE = 30 -- seconds a selected workspace's status stays fresh when it is clicked again

local function fresh_pages()
	return { home = 1, mirrors = 1, prs = 1, wis = 1, worksets = 1 }
end

export type Env = {
	surface: string, -- "sidebar" | "block"
	dev: any, -- the dev port: DevCli or anything with the same operations
	redraw: (cx: any) -> (),
	effect: (cx: any, kind: string, data: { [string]: any }) -> (),
}

export type Failure = {
	op: string,
	input: { [string]: any },
	label: string,
	error: any,
	remedies: { Remedies.Remedy },
}

function Store.new(env: Env)
	return {
		env = env,
		dev = env.dev,
		root = nil, -- root picked in the UI (kv "root"); nil follows dev's own choice, the default
		active_root = nil, -- what dev resolved
		root_source = nil,
		roots = {},
		roots_error = nil,
		workspaces = {},
		mirrors = {},
		workspaces_stale = false,
		mirrors_stale = false,
		mirrors_error = nil,
		pr_query = { scope = "mine", status = "open" }, -- committed, root-scoped provider query
		prs_request = nil,
		prs_seq = 0,
		prs = nil,
		status = {}, -- [workspace] = { data?, error?, loading }
		folders = {}, -- folders outside the tracked mounts
		worksets = nil,
		labels = nil,
		catalog = nil,
		catalog_error = nil,
		worksets_error = nil,
		labels_error = nil,
		workset_detail = nil,
		workset_draft = nil,
		creation = nil,
		creation_seq = 0,
		creation_request = nil,
		creation_error = nil,
		workset_save_error = nil,
		live_selection = nil,
		plan = nil, -- { ws, data }
		screen = "home", -- home | ws | mirrors | prs | pr | wis | wi | roots | ref | mirror | search
		selected = nil,
		busy = {}, -- [op] = label
		notice = nil, -- { tone, text, sub }
		failure = nil, -- Failure
		confirm = nil, -- { title, lines, tone, variant, op, input, label }
		loading = false,
		loading_since = nil,
		reload = false,
		load_error = nil,
		loaded_at = nil,
		gen = 0,
		filter = "",
		active_ws = nil, -- workspace holding the focused pane (sidebar only)
		workspace_tabs = {}, -- [workspace] = overview | repositories | files
		cursor = nil, -- workspace the keyboard selection is on (block only)
		pr = nil, -- { ref, data?, error?, loading } the pull request on screen "pr"
		wis = nil, -- work items from the cache, or nil before the first read
		wi = nil, -- { id, data?, error?, loading } the work item on screen "wi"
		search = nil, -- { query, results?, error?, loading }
		checked = {}, -- [workspace] = when its status was last read (os.time)
		checking = {}, -- [workspace] = true while Store.check reads it
		attempted = {}, -- [workspace] = when a status read last ended, answered or not (throttles Store.check)
		ops = {}, -- [busy key] = identity of the operation that set it, so a late answer clears only its own marker
		epoch = 0, -- counts root changes; an answer started in an earlier epoch belongs to another root
		prs_error = nil, -- why the last pull request read failed (s.prs keeps the last list, if any)
		prs_warning = nil, -- successful providers returned data, but the collection is incomplete
		planning = nil, -- identity of the dry-run whose answer may still become s.plan
		pages = fresh_pages(), -- [collection] = presentation page, 1-based
		files = {}, -- [workspace] = file browser of the selected workspace, see new_browser
		browse = nil, -- file browser of the mirror on screen "mirror"
		modal = nil, -- "create" | "add" | "workset" | "live"
		modal_ws = nil,
		modal_workset = nil,
		modal_seq = 0,
	}
end

local function redraw(s, cx)
	s.env.redraw(cx)
end

-- What an operation started now belongs to: the root lifecycle (epoch) and the root it reads. An answer is only
-- applied while `current` still holds; a refresh of the same root does not end it.
local function context(s)
	return { epoch = s.epoch, root = s.active_root }
end

local function current(s, ctx): boolean
	return ctx.epoch == s.epoch and Store.norm(ctx.root) == Store.norm(s.active_root)
end

-- Marks `key` busy for one operation; only that operation's `end_op` clears it.
local function begin_op(s, key: string, label: string)
	local token = {}
	s.ops[key] = token
	s.busy[key] = label
	return token
end

local function end_op(s, key: string, token)
	if s.ops[key] == token then
		s.ops[key] = nil
		s.busy[key] = nil
	end
end

-- `input` with the root this store reads. An input that names its own root or cwd keeps them: only a root this
-- store reads can resolve a workspace name through its list.
local function rooted(s, input: { [string]: any }?): { [string]: any }
	local root = if input and input.root then input.root else s.active_root
	local out = { root = root, cwd = root }
	for k, v in input or {} do
		out[k] = v
	end
	if out.ws and not (input and input.cwd) and Store.norm(root) == Store.norm(s.active_root) then
		local w = Store.workspace(s, out.ws)
		if w then out.cwd = w.path end
	end
	return out
end

function Store.workspace(s, name: string?)
	if not name then
		return nil
	end
	for _, w in s.workspaces do
		if w.name == name then
			return w
		end
	end
	return nil
end

-- Comparable form of a path: forward slashes, no trailing slash, drive paths case-folded.
function Store.norm(path: string?): string
	local p = string.gsub(tostring(path or ""), "\\", "/")
	p = string.gsub(p, "/+$", "")
	if string.match(p, "^%a:") then
		p = string.lower(p)
	end
	return p
end

-- The registered root at `path`, or nil.
function Store.root_entry(s, path: string?)
	if not path then
		return nil
	end
	local want = Store.norm(path)
	for _, r in s.roots do
		if Store.norm(r.path) == want then
			return r
		end
	end
	return nil
end

-- The workspace whose folder holds `path` (itself or below it), or nil.
function Store.locate(s, path: string?)
	local want = Store.norm(path)
	if want == "" then
		return nil
	end
	for _, w in s.workspaces do
		local root = Store.norm(w.path)
		if root ~= "" and (want == root or string.sub(want, 1, #root + 1) == root .. "/") then
			return w
		end
	end
	return nil
end

-- Native pane kinds whose location is a shell cwd, and those that carry a native path. Plugin blocks (this
-- navigator included), browsers and path-less kinds say nothing about where work is open.
local CWD_KINDS = { terminal = true, agent = true }
local PATH_KINDS = { file = true, git = true, database = true, notebook = true, board = true, canvas = true }

-- The deepest registered root that is `path` or an ancestor of it, by directory boundary. `roots` is keyed by
-- Store.norm. A filesystem root normalises to "" and owns nothing, as in Store.locate.
local function owning_root(roots: { [string]: boolean }, path: string): string?
	local p = path
	while p ~= "" do
		if roots[p] then
			return p
		end
		local cut = string.match(p, "^(.*)/[^/]*$")
		if cut == nil or cut == p then
			return nil
		end
		p = cut
	end
	return nil
end

local function pane_place(pane): string?
	local kind = pane.kind
	local raw
	if CWD_KINDS[kind] then
		raw = pane.cwd
	elseif PATH_KINDS[kind] then
		raw = pane.path
	end
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local place = Store.norm(raw)
	return if place == "" then nil else place
end

-- Where the observed native window shows each workspace: one entry per workspace root (indexed by
-- Store.norm(path)) that holds at least one live tab of a session on the snapshot's host. A tab counts once
-- however many panes it splits into. The snapshot never covers other windows, so a workspace without an entry
-- is "not observed", never "closed". Pure and synchronous over metadata the window already holds.
function Store.match_presence(workspaces, observation)
	local out = {}
	if type(observation) ~= "table" or observation.available ~= true or type(workspaces) ~= "table" then
		return out
	end
	local roots = {}
	for _, w in workspaces do
		local root = Store.norm(w.path)
		if root ~= "" then
			roots[root] = true
		end
	end
	if next(roots) == nil then
		return out
	end
	local session_of, session_order = {}, {}
	for i, session in observation.sessions or {} do
		if type(session) == "table" and session.id ~= nil and session.host == observation.host then
			session_of[session.id] = session
			session_order[session.id] = i
		end
	end
	local tab_of, tab_order = {}, {}
	for i, tab in observation.tabs or {} do
		if type(tab) == "table" and tab.id ~= nil and session_of[tab.session] ~= nil then
			tab_of[tab.id] = tab
			tab_order[tab.id] = i
		end
	end
	-- tab id -> root -> pane that shows it (the tab's focused pane when that one matches, else the first).
	local found = {}
	for _, pane in observation.panes or {} do
		local tab = if type(pane) == "table" and pane.parked ~= true then tab_of[pane.tab] else nil
		local place = if tab then pane_place(pane) else nil
		local root = if place then owning_root(roots, place) else nil
		if root then
			local per = found[tab.id]
			if per == nil then
				per = {}
				found[tab.id] = per
			end
			if per[root] == nil or pane.pane == tab.pane then
				per[root] = pane.pane
			end
		end
	end
	local tab_ids = {}
	for id in found do
		table.insert(tab_ids, id)
	end
	table.sort(tab_ids, function(a, b)
		local sa, sb = session_order[tab_of[a].session], session_order[tab_of[b].session]
		if sa ~= sb then
			return sa < sb
		end
		return tab_order[a] < tab_order[b]
	end)
	for _, id in tab_ids do
		local tab = tab_of[id]
		local session = session_of[tab.session]
		local tab_name = if type(tab.name) == "string" and tab.name ~= "" then tab.name elseif type(tab.title) == "string" and tab.title ~= "" then tab.title else "Tab " .. tostring(id)
		for root, pane in found[id] do
			local entry = out[root]
			if entry == nil then
				entry = { count = 0, destinations = {} }
				out[root] = entry
			end
			entry.count += 1
			table.insert(entry.destinations, {
				session = session.id,
				session_name = tostring(session.name or ""),
				tab = id,
				tab_name = tab_name,
				pane = pane,
			})
		end
	end
	return out
end

-- The last observation of the native window, or nil while none arrived. Kept raw; matching is derived.
function Store.set_presence(s, observation)
	s.presence = if type(observation) == "table" then observation else nil
end

-- Workspace refresh replaces the inventory rather than mutating its paths. Cache by that inventory, the
-- native observation and the active root; row lookups must not rescan every path on every render.
function Store.presence_map(s)
	local cache = s.presence_cache
	if cache == nil or cache.observation ~= s.presence or cache.workspaces ~= s.workspaces or cache.root ~= s.active_root then
		cache = {
			observation = s.presence,
			workspaces = s.workspaces,
			root = s.active_root,
			map = Store.match_presence(s.workspaces, s.presence),
		}
		s.presence_cache = cache
	end
	return cache.map
end

-- The positive presence entry of workspace `w` ({count, destinations}), or nil when this snapshot did not
-- observe it (which says nothing about whether it is open elsewhere).
function Store.presence_for(s, w)
	return Store.presence_map(s)[Store.norm(w.path)]
end

local function chosen_root(): string?
	local ok, value = pcall(tern.kv.get, "root")
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function choose_root(value: string?)
	pcall(tern.kv.set, "root", value)
end

-- Data belongs to one resolved root, including identically named workspaces in another root.
local function clear_root(s)
	s.epoch += 1
	s.status, s.folders, s.checked, s.attempted, s.checking = {}, {}, {}, {}, {}
	s.ops, s.busy = {}, {}
	s.prs, s.prs_error, s.prs_warning, s.wis, s.pr, s.wi, s.search, s.ask = nil, nil, nil, nil, nil, nil, nil, nil
	s.pr_query = { scope = "mine", status = "open" }
	s.prs_seq += 1
	s.prs_request = nil
	s.worksets, s.labels, s.catalog = nil, nil, nil
	s.worksets_error, s.labels_error, s.catalog_error = nil, nil, nil
	s.workset_detail, s.workset_draft = nil, nil
	s.creation, s.creation_request, s.creation_error = nil, nil, nil
	s.workset_save_error = nil
	s.creation_seq += 1
	s.live_selection = nil
	s.plan, s.planning, s.confirm = nil, nil, nil
	s.failure, s.after_load = nil, nil
	s.workspaces, s.mirrors = {}, {}
	s.workspaces_stale, s.mirrors_stale = false, false
	s.selected, s.active_ws, s.screen = nil, nil, "home"
	s.filter = ""
	s.loaded_at = nil
	s.modal_seq += 1
	s.files, s.browse, s.modal, s.modal_ws, s.modal_workset, s.pages = {}, nil, nil, nil, nil, fresh_pages()
	s.workspace_tabs = {}
end

-- Lists the folders of workspace `w` that are no mount, then asks git, one repository at a time, what each holds
-- that exists nowhere else (see DevCli.git_folder). A state read before stays shown until the new one comes.
local function load_folders(s, gen: number, w, mounts: { string })
	local name, epoch = w.name, s.epoch
	local before = {}
	for _, f in s.folders[name] or {} do
		before[f.name] = f.repo
	end
	local list = s.dev.folders(tostring(w.path), mounts)
	local repos = {}
	for _, f in list do
		f.repo = before[f.name]
		if f.git then
			table.insert(repos, f)
		end
	end
	s.folders[name] = list
	local function step(i: number)
		local f = repos[i]
		if f == nil or gen ~= s.gen or epoch ~= s.epoch then
			return
		end
		s.dev.git_folder(f.path, function(repo, cx)
			if gen == s.gen and epoch == s.epoch then
				f.repo = repo
				redraw(s, cx)
				step(i + 1)
			end
		end)
	end
	step(1)
end

local load_commits -- set with the file browsers below

-- Records a status answer for workspace `w` and re-reads the folders dev does not track beside its mounts.
local function take_status(s, gen: number, w, r)
	local name = w.name
	local prev = s.status[name]
	s.status[name] = if r.ok then { data = r.value, loading = false }
		else { data = prev and prev.data, error = r.error, loading = false, stale = prev ~= nil and prev.data ~= nil }
	s.attempted[name] = os.time()
	if r.ok then s.checked[name] = os.time() end
	if r.ok then
		local mounts = {}
		for _, m in (type(r.value) == "table" and r.value.mounts) or {} do
			table.insert(mounts, tostring(m.path))
		end
		load_folders(s, gen, w, mounts)
		load_commits(s, w, mounts)
	end
end

-- File browsers ---------------------------------------------------------------------------------------------------
-- A browser is { name, mirror?, root, open = { [dir] = boolean }, pages = { [dir] = page > 1 }, dirs = { [dir] =
-- { entries, total, offset, loading, error? } }, manifest = { text?, modifiedAt?, error? }, activity = { { name,
-- path, modifiedAt, kind } } }. A directory holds only the page on screen: at most FILE_PAGE entries, the count of
-- all of them (`total`) and the 0-based `offset` the dev port answered with. The port sorts the whole directory
-- before slicing, so a page never changes when another loads. A request keeps the page shown until its answer
-- replaces it, and an answer lands only in the browser and directory entry that asked: a root change, a refresh
-- or a newer request for the directory drops it. All file access goes through the dev port: read_dir, manifest.

local function join(parent: string, name: string): string
	return (string.gsub(parent, "[/\\]+$", "")) .. (if string.find(parent, "\\") then "\\" else "/") .. name
end

local function error_text(e): string
	return tostring(e.message) .. (if e.nextStep then " " .. e.nextStep else "")
end

-- Calls port function `name` with `...` and `land`; `land` also hears a missing or raising port.
local function request(s, name: string, land, ...)
	local fn = s.dev[name]
	if type(fn) ~= "function" then
		return land({ ok = false, error = { code = "UNAVAILABLE", message = "File access is not available.", details = {} } }, nil)
	end
	local args = { ... }
	table.insert(args, land)
	local ok, err = pcall(fn, table.unpack(args))
	if not ok then
		land({ ok = false, error = { code = "PLUGIN", message = tostring(err), details = {} } }, nil)
	end
end

local function new_browser(root: string, name: string?, mirror: boolean?)
	return { name = name, mirror = mirror, root = root, open = { [root] = true }, dirs = {}, pages = {}, manifest = {}, activity = {}, base = {}, extra = {} }
end

local function alive(s, b): boolean
	if b.mirror then
		return s.browse == b
	end
	return s.files[b.name] == b
end

local function rebuild_activity(b)
	local out = {}
	for _, a in b.base do
		table.insert(out, a)
	end
	for _, a in b.extra do
		table.insert(out, a)
	end
	table.sort(out, function(x, y)
		if x.modifiedAt ~= y.modifiedAt then
			return x.modifiedAt > y.modifiedAt
		end
		return x.name < y.name
	end)
	b.activity = out
end

-- Requests `dir` of `b` at `offset` (0-based).
local function read_dir(s, cx, b, dir: string, offset: number)
	local prev = b.dirs[dir]
	local d = { entries = prev and prev.entries or {}, total = prev and prev.total or 0, offset = prev and prev.offset or 0, loading = true }
	b.dirs[dir] = d
	request(s, "read_dir", function(r, c)
		if not d.loading or b.dirs[dir] ~= d or not alive(s, b) then
			return
		end
		d.loading = false
		if r.ok then
			d.entries, d.total, d.offset, d.error = r.value.entries, r.value.total, r.value.offset, nil
			local page = d.offset // FILE_PAGE + 1
			b.pages[dir] = if page > 1 then page else nil
		elseif r.error.code == "ENOENT" and dir ~= b.root then
			b.open[dir], b.dirs[dir], b.pages[dir] = nil, nil, nil -- the folder is gone
		else
			d.error = error_text(r.error)
		end
		redraw(s, c or cx)
	end, dir, offset)
end

-- Requests again every directory `b` has open, at the page it shows.
local function read_open(s, cx, b)
	for dir, on in b.open do
		if on then
			read_dir(s, cx, b, dir, ((b.pages[dir] or 1) - 1) * FILE_PAGE)
		end
	end
end

-- A browser of `root` that keeps what `prev` (same root) had expanded, shown and read, until new answers come.
local function fresh_browser(root: string, name: string?, mirror: boolean?, prev)
	local b = new_browser(root, name, mirror)
	if prev and Store.norm(prev.root) == Store.norm(root) then
		for dir, on in prev.open do
			if on then
				b.open[dir], b.pages[dir], b.dirs[dir] = true, prev.pages[dir], prev.dirs[dir]
			end
		end
		b.manifest, b.extra = prev.manifest, prev.extra
	end
	return b
end

local function set_signal(b, key: string, item)
	b.extra[key] = item
	rebuild_activity(b)
end

local function load_manifest(s, cx, b)
	request(s, "manifest", function(r, c)
		if not alive(s, b) then
			return
		end
		if r.ok then
			b.manifest = { text = r.value.text, modifiedAt = r.value.modifiedAt }
			if r.value.modifiedAt then
				set_signal(b, "manifest", { name = "ws.md modified", path = join(b.root, "ws.md"), modifiedAt = r.value.modifiedAt, kind = "file" })
			end
		else
			b.manifest = { error = error_text(r.error) }
			set_signal(b, "manifest", nil)
		end
		redraw(s, c or cx)
	end, b.root)
end

-- ISO-8601 time as Unix seconds, or nil.
local function unix_seconds(iso: any): number?
	local y, mo, d, h, mi, sec, zone = string.match(tostring(iso or ""), "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)%.?%d*(.*)$")
	if not y then
		return nil
	end
	local year, month, day = tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number
	if month <= 2 then
		year -= 1
	end
	local era = year // 400
	local yoe = year - era * 400
	local doy = (153 * (month + (if month > 2 then -3 else 9)) + 2) // 5 + day - 1
	local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
	local t = days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(sec) :: number)
	local sign, zh, zm = string.match(zone, "^([+-])(%d%d):?(%d%d)$")
	if sign then
		local offset = (tonumber(zh) :: number) * 3600 + (tonumber(zm) :: number) * 60
		t = if sign == "+" then t - offset else t + offset
	end
	return t
end

-- What the workspace record and the files say: `used` is when dev last used the workspace, `created` when it was
-- made (both recorded by dev); `file` is a modification time read from the file system (ws.md); `commit` is the
-- newest commit of a mounted repository. None of them proves recent code edits.
local function activity_of(w)
	local out = {}
	for _, spec in { { "lastUsedAt", "used", "Last used with dev" }, { "createdAt", "created", "Created by dev" } } do
		local t = unix_seconds(w[spec[1]])
		if t then
			table.insert(out, { name = spec[3], path = tostring(w.path), modifiedAt = t, kind = spec[2] })
		end
	end
	return out
end

-- (Re)reads workspace `w`'s browser, keeping the directories that were expanded and are still there.
local function load_browser(s, cx, w)
	local b = fresh_browser(tostring(w.path), w.name, false, s.files[w.name])
	b.base = activity_of(w)
	rebuild_activity(b)
	s.files[w.name] = b
	read_open(s, cx, b)
	load_manifest(s, cx, b)
end

-- The newest commit of each repository mounted in `w`, one git read at a time, into its browser.
function load_commits(s, w, mounts: { string })
	local b = s.files[w.name]
	if not b or type(s.dev.last_commit) ~= "function" then
		return
	end
	local epoch = s.epoch
	local function step(i: number)
		local m = mounts[i]
		if not m or s.files[w.name] ~= b or epoch ~= s.epoch then
			return
		end
		local full = join(b.root, m)
		s.dev.last_commit(full, function(t, c)
			if s.files[w.name] ~= b or epoch ~= s.epoch then
				return
			end
			if t then
				set_signal(b, "commit:" .. m, { name = "Last commit in " .. m, path = full, modifiedAt = t, kind = "commit" })
				redraw(s, c)
			end
			step(i + 1)
		end)
	end
	step(1)
end

local function find_mirror(s, name: string?)
	for _, m in s.mirrors do
		if m.name == name then
			return m
		end
	end
	return nil
end

local function inside(root: string, path: string): boolean
	local r, p = Store.norm(root), Store.norm(path)
	return r ~= "" and (p == r or string.sub(p, 1, #r + 1) == r .. "/")
end

-- The browser on screen that holds `path`; a path of another root or workspace belongs to none.
local function browser_at(s, path: string)
	if s.screen == "mirror" and s.browse and inside(s.browse.root, path) then
		return s.browse
	end
	local b = s.selected and s.files[s.selected]
	if b and inside(b.root, path) then
		return b
	end
	return nil
end

-- The entry on screen for `path` (an open directory's current page, exact as the entry gave it), or nil.
local function entry_at(b, path: string)
	local parent = string.match(path, "^(.*)[/\\][^/\\]+$")
	local d = parent and b.open[parent] and b.dirs[parent]
	for _, e in (d and d.entries) or {} do
		if e.path == path then
			return e
		end
	end
	return nil
end

local function files_toggle(s, cx, path: string): boolean
	local b = browser_at(s, path)
	if not b or Store.norm(path) == Store.norm(b.root) then
		return false
	end
	local e = entry_at(b, path)
	if not (e and e.directory) then
		return false
	end
	if b.open[path] then
		b.open[path] = false
		b.pages[path] = nil
	else
		b.open[path] = true
		b.pages[path] = nil
		read_dir(s, cx, b, path, 0)
	end
	return true
end

-- `value` is "<directory>:<page>", split at the last colon: reads that page of an open directory (the port clamps
-- a page past the end to the last one). The page shown stays until the answer replaces it.
local function files_page(s, cx, value: string): boolean
	local dir, n = string.match(value, "^(.*):(%d+)$")
	local b = dir and browser_at(s, dir)
	local page = tonumber(n)
	if not (b and b.open[dir] and b.dirs[dir] and page and page >= 1) then
		return false
	end
	read_dir(s, cx, b, dir, (page - 1) * FILE_PAGE)
	return true
end

local function files_open(s, cx, path: string)
	local b = browser_at(s, path)
	local e = b and entry_at(b, path)
	if e and not e.directory then
		s.env.effect(cx, "edit", { path = e.path })
	end
end

-- Where a screen change leaves a mirror's browser behind.
local function show(s, screen: string)
	s.screen = screen
	if screen ~= "mirror" then
		s.browse = nil
	end
end

local function invalidate_creation_state(s)
	s.creation_seq += 1
	s.creation_request, s.creation, s.creation_error = nil, nil, nil
end

local function close_modal(s)
	s.modal, s.modal_ws, s.modal_workset = nil, nil, nil
	s.modal_seq += 1
	invalidate_creation_state(s)
	s.workset_detail, s.live_selection, s.workset_draft = nil, nil, nil
	s.workset_save_error = nil
end

local function open_modal(s, kind: string, ws: string?)
	s.modal, s.modal_ws, s.modal_workset = kind, ws, nil
	s.modal_seq += 1
	invalidate_creation_state(s)
	s.workset_detail, s.live_selection, s.workset_draft = nil, nil, nil
	s.workset_save_error, s.failure = nil, nil
end

-- Inspecting a workspace: its browser, and either its status (mounts) or its untracked folders (none). Clicking a
-- workspace reads this one only; the rest of the list keeps what was read before.
function Store.inspect(s, cx, name: string?)
	local w = Store.workspace(s, name)
	if not w then
		return
	end
	load_browser(s, cx, w)
	if (tonumber(w.mountCount) or 0) == 0 then
		load_folders(s, s.gen, w, {})
	else
		Store.check(s, cx, w.name, { max_age = INSPECT_MAX_AGE })
	end
end

-- After a refresh: re-reads the selected workspace's browser, the mirror on screen, and the status of the selected
-- and focused workspaces, one at a time with a short gap, so neither the UI thread nor dev is flooded. A newer
-- refresh (gen) abandons the chain. Every other status read before is kept, marked stale.
local function load_details(s, gen: number, cx)
	local selected = Store.workspace(s, s.selected)
	for name in s.files do
		if not selected or name ~= selected.name then
			s.files[name] = nil
		end
	end
	if selected then
		load_browser(s, cx, selected)
	end
	if s.browse then
		local m = find_mirror(s, s.browse.name)
		if m and Store.norm(m.path) == Store.norm(s.browse.root) then
			local b = fresh_browser(s.browse.root, s.browse.name, true, s.browse)
			s.browse = b
			read_open(s, cx, b)
		else
			s.browse = nil
			if s.screen == "mirror" then
				s.screen = "mirrors"
			end
		end
	end
	if s.modal == "add" and not Store.workspace(s, s.modal_ws) then
		close_modal(s)
	end
	local wanted = { [s.selected or ""] = true, [s.active_ws or ""] = true }
	local queue = {}
	for _, w in s.workspaces do
		local prev = s.status[w.name]
		if (tonumber(w.mountCount) or 0) == 0 then
			s.status[w.name] = nil
			if wanted[w.name] then
				load_folders(s, gen, w, {})
			end
		elseif wanted[w.name] and not s.checking[w.name] then
			table.insert(queue, w)
			s.status[w.name] = { data = prev and prev.data, loading = true, stale = prev ~= nil and prev.data ~= nil }
		elseif prev and prev.data ~= nil and not prev.loading then
			prev.stale = true
		end
	end
	local function step(i: number)
		if gen ~= s.gen or i > #queue then
			return
		end
		local w = queue[i]
		s.checking[w.name] = true
		s.dev.status(rooted(s, { ws = w.name }), function(r, cx)
			if gen ~= s.gen then
				return
			end
			s.checking[w.name] = nil
			take_status(s, gen, w, r)
			redraw(s, cx)
			tern.timer(STATUS_GAP_MS, function()
				step(i + 1)
			end)
		end)
	end
	step(1)
end

-- Re-reads one workspace's status when the last attempt is older than `max_age` seconds (the status line asks as
-- the focused pane moves); `refresh` fetches the remotes first. `done(ok)` runs after the answer, when given: ok
-- is false when the read failed or its answer was not applied (another root by then).
function Store.check(s, cx, name: string, opts: { max_age: number?, refresh: boolean? }?, done: ((boolean) -> ())?)
	local o = opts or {}
	local w = Store.workspace(s, name)
	if not w or (tonumber(w.mountCount) or 0) == 0 or s.checking[name] then
		return
	end
	-- Throttle by the last attempt: a persistent error must not be retried on every focus change, and it never
	-- counts as a successful check (s.checked).
	if o.max_age and s.attempted[name] and os.time() - s.attempted[name] < o.max_age then
		return
	end
	local ctx = context(s)
	local key = "check:" .. name
	local token = {}
	local previous = s.status[name]
	local entry = { data = previous and previous.data, loading = true, stale = previous ~= nil and previous.data ~= nil }
	s.status[name] = entry
	s.checking[name] = token
	if o.refresh then
		s.ops[key] = token
		s.busy[key] = "Checking remotes of " .. name .. "…"
		redraw(s, cx)
	end
	s.dev.status(rooted(s, { ws = name, refresh = o.refresh }), function(r, c)
		-- A refresh of the same root may have taken over the markers meanwhile; clear only this check's own.
		if s.checking[name] == token then s.checking[name] = nil end
		end_op(s, key, token)
		if not current(s, ctx) then
			-- Another root now: nothing of this answer belongs here, but the caller still hears the check ended.
			if done then done(false) end
			return
		end
		local live = Store.workspace(s, name)
		if live then
			-- Publish only while this check's own reading entry is still the workspace's status: a refresh or a
			-- younger check that replaced it holds a newer observation, which an older answer must not undo.
			if s.status[name] == entry then
				take_status(s, s.gen, live, r)
			end
			if o.refresh and not r.ok then
				s.notice = { tone = "warning", text = "Could not check the remotes of " .. name, sub = r.error.message }
			elseif o.refresh then
				s.notice = { tone = "success", text = "Remotes checked: " .. name }
			end
		end
		redraw(s, c)
		if done then
			done(live ~= nil and r.ok)
		end
	end)
end

-- A refresh that ends leaves no status reading: the chain a newer refresh abandoned never reports back. A read
-- with data stays shown, stale; one without data says it was interrupted. After a failed reload every retained
-- observation is stale too.
local function settle_statuses(s)
	for _, st in s.status do
		if st.loading then
			st.loading = false
			if st.data == nil then
				st.error = st.error or { code = "STATUS_INTERRUPTED", message = "Reading the workspace status was interrupted by a reload.", details = {} }
			end
		end
		if s.load_error and st.data ~= nil then
			st.stale = true
		end
	end
end

-- A refresh older than this is presumed lost (a callback that never came) and may be replaced.
local STUCK_MS = 5 * 60 * 1000

-- Reloads roots, the root to read, workspaces and mirrors, then each workspace's status. A refresh in flight
-- absorbs automatic calls (one more runs after it); `force` (a person asked) starts over at once.
function Store.refresh(s, cx, force: boolean?)
	if s.loading and not force and tern.now() - (s.loading_since or 0) < STUCK_MS then
		s.reload = true
		return
	end
	s.loading = true
	s.loading_since = tern.now()
	s.reload = false
	s.gen += 1
	local gen = s.gen
	s.checking = {}
	for key in s.busy do
		if string.sub(key, 1, 6) == "check:" then
			s.busy[key] = nil
			s.ops[key] = nil
		end
	end
	s.root = chosen_root()
	redraw(s, cx)
	local function finish(c)
		if gen ~= s.gen then
			return
		end
		s.loading = false
		settle_statuses(s)
		if not s.load_error and not s.mirrors_error then s.loaded_at = os.time() end
		local after = s.after_load
		if after then
			s.after_load = nil
			after(c)
		end
		redraw(s, c)
		if s.reload then
			Store.refresh(s, c)
		elseif not s.load_error then
			load_details(s, gen, c)
		end
	end
	-- Each step runs guarded: a plugin error ends this refresh with a visible error instead of leaving
	-- `loading` set forever, which would swallow every later refresh.
	local function step(fn)
		return function(r, c)
			if gen ~= s.gen then
				return
			end
			local ok, err = pcall(fn, r, c)
			if not ok and gen == s.gen then
				s.load_error = { code = "PLUGIN", message = "The dev plugin failed while reading dev.", detail = tostring(err), details = {} }
				tern.log.warn("devcli: refresh failed: " .. tostring(err))
				finish(c)
			end
		end
	end
	s.dev.roots(nil, step(function(roots, c1)
		s.roots = if roots.ok then roots.value else {}
		s.roots_error = if roots.ok then nil else roots.error
		-- dev accepts any root path, even a folder that is not a root, and answers with empty lists; so a
		-- picked root that is no longer registered falls back to the default instead of showing nothing.
		if s.root and roots.ok and not Store.root_entry(s, s.root) then
			s.notice = { tone = "warning", text = "Root no longer registered; using the default", sub = s.root }
			s.root = nil
			choose_root(nil)
		end
		s.dev.current({ root = s.root }, step(function(current, c2)
			if not current.ok then
				s.load_error = current.error
				if s.root and Store.norm(s.root) ~= Store.norm(s.active_root) then
					clear_root(s)
					s.active_root = nil
				end
				s.workspaces_stale, s.mirrors_stale = true, true
				finish(c2 or c1)
				return
			end
			s.load_error = nil
			if s.active_root ~= nil and Store.norm(s.active_root) ~= Store.norm(current.value.root) then clear_root(s) end
			s.active_root = current.value.root
			s.root_source = current.value.source
			s.dev.workspaces(rooted(s), step(function(ls, c3)
				if ls.ok then
					table.sort(ls.value, function(a, b)
						-- One stable order: names without regard to case. Activity is shown on the row, never moves it.
						local la, lb = string.lower(tostring(a.name)), string.lower(tostring(b.name))
						if la ~= lb then
							return la < lb
						end
						return tostring(a.name) < tostring(b.name)
					end)
					s.workspaces = ls.value
					s.workspaces_stale = false
				else
					s.load_error = ls.error
					s.workspaces_stale = true
				end
				s.dev.mirrors(rooted(s), step(function(mirrors, c4)
					if mirrors.ok then s.mirrors = mirrors.value end
					s.mirrors_stale = not mirrors.ok
					s.mirrors_error = if mirrors.ok then nil else mirrors.error
					finish(c4 or c3 or c2 or c1)
				end))
			end))
		end))
	end))
end

fail = function(s, op: string, input, label: string, err)
	s.failure = {
		op = op,
		input = input,
		label = label,
		error = err,
		remedies = Remedies.for_failure(op, input, err),
	}
end

local PR_STATUSES = { open = true, completed = true, abandoned = true, closed = true, all = true }

local function clean_query(value): { [string]: any }?
	if type(value) ~= "table" or (value.scope ~= "mine" and value.scope ~= "all")
		or not PR_STATUSES[value.status or "open"] then
		return nil
	end
	local query = { scope = value.scope, status = value.status or "open" }
	for _, field in { "repo", "provider", "project", "ws", "label" } do
		local item = value[field]
		if item ~= nil then
			if type(item) ~= "string" then return nil end
			item = string.gsub(item, "^%s*(.-)%s*$", "%1")
			if item ~= "" then query[field] = item end
		end
	end
	if query.label and (query.repo or query.ws) then return nil end
	return query
end

function Store.load_prs(s, cx, live: boolean, query)
	if s.busy.pull_requests then return false end
	local committed = clean_query(query or s.pr_query) or { scope = "mine", status = "open" }
	local token = {}
	local op_token = begin_op(s, "pull_requests", if live then "Fetching pull requests…" else "Reading cached pull requests…")
	s.prs_request = token
	local ctx = context(s)
	local input = rooted(s, committed)
	input.live = live == true
	local seq = s.prs_seq
	s.prs_error = nil
	redraw(s, cx)
	local function done(r, c)
		end_op(s, "pull_requests", op_token)
		if s.prs_request ~= token or s.prs_seq ~= seq or not current(s, ctx) then return end
		s.prs_request = nil
		if r.ok then
			s.prs, s.prs_warning = r.value, r.warning
			s.prs_error = nil
		else
			-- This is still the committed query; retain its last answer on a failed refresh.
			s.prs_error = r.error
			fail(s, "pull_requests", input, "List pull requests", r.error)
		end
		redraw(s, c or cx)
	end
	local ok, err = pcall(s.dev.pull_requests, input, done)
	if not ok then done({ ok = false, error = { code = "PLUGIN", message = tostring(err), details = {} } }, nil) end
	return true
end

local function commit_pr_query(s, cx, value): boolean
	local query = clean_query(value)
	if not query or s.busy.pull_requests then return false end
	s.pr_query = snapshot(query)
	s.prs_seq += 1
	s.prs_request = nil
	s.prs, s.prs_error, s.prs_warning = nil, nil, nil
	close_modal(s)
	Store.load_prs(s, cx, false, s.pr_query)
	return true
end

-- Cached, root-scoped sources. A failed refresh keeps the last successful collection visible.
function Store.load_sources(s, cx)
	local ctx = context(s)
	local input = rooted(s)
	for _, spec in {
		{ op = "worksets", field = "worksets", error = "worksets_error" },
		{ op = "labels", field = "labels", error = "labels_error" },
		{ op = "catalog", field = "catalog", error = "catalog_error" },
	} do
		local entry = spec
		s[entry.error] = nil
		request(s, entry.op, function(r, c)
			if not current(s, ctx) then return end
			if r.ok then
				s[entry.field], s[entry.error] = r.value, nil
			else
				s[entry.error] = r.error
			end
			redraw(s, c or cx)
		end, input)
	end
end

function Store.load_worksets(s, cx)
	local ctx = context(s)
	s.worksets_error = nil
	local token = {}
	s.worksets_request = token
	request(s, "worksets", function(r, c)
		if not current(s, ctx) or s.worksets_request ~= token then return end
		if r.ok then s.worksets, s.worksets_error = r.value, nil else s.worksets_error = r.error end
		redraw(s, c or cx)
	end, rooted(s))
end

function Store.load_workset(s, cx, name: string)
	local ctx, modal_seq = context(s), s.modal_seq
	local entry = { name = name, loading = true }
	s.workset_detail = entry
	request(s, "workset", function(r, c)
		if not current(s, ctx) or s.modal_seq ~= modal_seq or s.modal ~= "workset" or s.workset_detail ~= entry then return end
		entry.loading = false
		if r.ok then entry.data = r.value else entry.error = r.error end
		redraw(s, c or cx)
	end, rooted(s, { name = name }))
	redraw(s, cx)
end

function Store.save_workset(s, cx, input)
	local ctx, seq = context(s), s.modal_seq
	local req = { name = input.name, original_name = input.original_name, definition = snapshot(input.definition) }
	s.workset_save_error, s.failure = nil, nil
	local token = {}
	s.workset_save_request = token
	local port_input = rooted(s, req)
	local function completed(r, c)
		if not current(s, ctx) or s.modal_seq ~= seq or s.workset_save_request ~= token then return end
		if not r.ok then
			s.workset_save_error = r.error
			fail(s, "save_workset", port_input, "Save workset", r.error)
			redraw(s, c or cx)
			return
		end
		s.workset_save_error = nil
		s.workset_detail = { name = r.value.name, data = r.value, loading = false }
		Store.load_worksets(s, c or cx)
		close_modal(s)
		s.workset_draft = nil
		redraw(s, c or cx)
	end
	request(s, "save_workset", completed, port_input)
end

-- Runs a changing operation with a busy marker; `on_ok(value, cx)` handles success. A refusal becomes a
-- failure card with the remedies for that (operation, code).
local function mutate(s, cx, op: string, input, label: string, on_ok: (any, any) -> (), accepts: (() -> boolean)?): boolean
	if s.busy[op] then
		return false
	end
	input = rooted(s, input)
	local ctx = context(s)
	local token = begin_op(s, op, label)
	s.failure = nil
	s.notice = nil
	s.confirm = nil
	redraw(s, cx)
	s.dev[op](input, function(r, c)
		end_op(s, op, token)
		if not current(s, ctx) then
			return -- the answer is for a root this store no longer shows
		end
		if accepts and not accepts() then return end
		if r.ok then
			on_ok(r.value, c)
		else
			fail(s, op, input, label, r.error)
		end
		redraw(s, c)
	end)
	return true
end

-- Tells the other surface (and this one) that dev state changed.
local function changed(s, c)
	s.env.effect(c, "refresh", {})
	Store.refresh(s, c)
end

-- Runs an operation whose success only needs a notice and a reload.
local function perform(s, cx, op: string, input, label: string)
	mutate(s, cx, op, input, label, function(value, c)
		s.notice = { tone = "success", text = label .. ": done" }
		if op == "update" then
			local sum = type(value) == "table" and value.summary
			if type(sum) == "table" then
				s.notice.sub = string.format(
					"%d changed · %d up to date · %d skipped",
					tonumber(sum.updated) or 0,
					tonumber(sum.upToDate) or 0,
					tonumber(sum.skipped) or 0
				)
			end
			s.plan = nil
		elseif op == "sync_mirrors" and #value.skipped > 0 then
			-- dev skips what it cannot sync and still succeeds; say so instead of "done".
			local first = value.skipped[1]
			s.notice = {
				tone = "warning",
				text = string.format("%s: %d skipped", label, #value.skipped),
				sub = (string.match(first.path, "[^/\\]+$") or first.path) .. ": " .. first.reason,
			}
		elseif op == "sync_mirrors" then
			s.notice.sub = string.format("%d updated · %d up to date", value.updated, value.up_to_date)
		end
		changed(s, c)
	end)
end

local function select_ws(s, name: string?, cx)
	s.selected = name
	show(s, if name then "ws" else "home")
	s.plan, s.planning = nil, nil
	s.confirm = nil
	for other in s.files do
		if other ~= name then
			s.files[other] = nil
		end
	end
	if name then
		Store.inspect(s, cx, name)
	end
end

local UPDATE_FLAGS = { autostash = true, rebase = true }

-- Dry-run first: the plan is the confirmation for an update.
local function plan_update(s, cx, ws: string)
	local token = {}
	local previous = s.planning
	s.planning = token
	local ctx = context(s)
	local started = mutate(s, cx, "update", { ws = ws, dry_run = true }, "Plan update of " .. ws, function(value, c)
		if s.planning ~= token then
			return -- the person left or closed it before the answer came
		end
		s.plan = { ws = ws, data = value, epoch = ctx.epoch, root = ctx.root }
		redraw(s, c)
	end)
	if not started then
		s.planning = previous
	end
end

-- Applies the reviewed plan, only in the root and workspace it was read for.
local function apply_update(s, cx, flag: string?)
	local plan = s.plan
	if not (current(s, plan) and Store.workspace(s, plan.ws)) then
		s.plan, s.planning = nil, nil
		s.notice = { tone = "warning", text = "The update plan no longer matches this workspace; plan it again." }
		redraw(s, cx)
		return
	end
	local input = { root = plan.root, ws = plan.ws }
	if flag and UPDATE_FLAGS[flag] then
		input[flag] = true
	end
	perform(s, cx, "update", input, "Update " .. plan.ws)
end

local function split_pair(value: string?): (string?, string?)
	if not value then
		return nil, nil
	end
	local a, b = string.match(value, "^(.-)|(.*)$")
	return a, b
end

-- The newest workspace by creation, for operations that name it themselves (PR checkout).
local function newest(s)
	local best = nil
	for _, w in s.workspaces do
		if not best or tostring(w.createdAt or "") > tostring(best.createdAt or "") then
			best = w
		end
	end
	return best and best.name
end

local REVIEW_AUTHORITY = {}

snapshot = function(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = snapshot(v) end
	return out
end

function Store.invalidate_creation(s)
	invalidate_creation_state(s)
	s.creation_error = nil
end

function Store.preview_workspace(s, cx, form)
	if s.modal ~= "create" then return end
	Store.invalidate_creation(s)
	local seq, ctx = s.modal_seq, context(s)
	local frozen = snapshot(form or {})
	local token = {}
	s.creation_request, s.creation_error, s.failure = token, nil, nil
	local input = rooted(s, { form = frozen })
	request(s, "create_plan", function(r, c)
		if not current(s, ctx) or s.modal ~= "create" or s.modal_seq ~= seq or s.creation_request ~= token then return end
		s.creation_request = nil
		if r.ok then
			s.creation = { data = snapshot(r.value), input = frozen, root = ctx.root, epoch = ctx.epoch, seq = seq }
			s.creation_error = nil
		else
			s.creation_error = r.error
			fail(s, "create_plan", input, "Preview workspace", r.error)
		end
		redraw(s, c or cx)
	end, input)
	redraw(s, cx)
end

function Store.create_workspace(s, cx, form)
	if type(form) ~= "table" or form.authority ~= REVIEW_AUTHORITY then return false end
	local plan = s.creation
	if not plan or plan.seq ~= form.seq or plan.seq ~= s.modal_seq or s.modal ~= "create"
		or not current(s, { epoch = plan.epoch, root = plan.root }) then return false end
	local seq = s.modal_seq
	local input = { name = plan.data.name, desc = plan.data.description, repositories = snapshot(plan.data.mounts) }
	local started = mutate(s, cx, "create", input, "Create workspace", function(value, c)
		local same_dialog = s.modal_seq == seq and s.modal == "create"
		if same_dialog then close_modal(s) end
		s.creation = nil
		if value.created then
			s.notice = { tone = "success", text = "Workspace created" }
		else
			s.notice = { tone = "info", text = "Workspace " .. tostring(input.name) .. " already existed; showing it" }
		end
		s.env.effect(c, "refresh", {})
		if same_dialog then
			local selection_seq = s.modal_seq
			s.after_load = function(c2)
				if s.modal_seq == selection_seq then
					select_ws(s, if Store.workspace(s, input.name) then input.name else newest(s), c2)
				end
			end
		end
		Store.refresh(s, c)
	end, function()
		return s.modal_seq == seq and s.modal == "create"
	end)
	return started
end

function Store.commit_workspace(s, cx)
	local plan = s.creation
	if not plan or s.modal ~= "create" or plan.seq ~= s.modal_seq or not current(s, plan) then
		Store.invalidate_creation(s)
		redraw(s, cx)
		return false
	end
	if plan.data.exists then return false end
	return Store.create_workspace(s, cx, { authority = REVIEW_AUTHORITY, seq = plan.seq })
end



-- `form`: { repo, branch, readonly }.
function Store.add_repo(s, cx, ws: string, form)
	local input = { ws = ws, repo = form.repo, branch = form.branch, readonly = form.readonly, path = form.path }
	local seq = s.modal_seq
	mutate(s, cx, "add", input, "Add repository", function(_, c)
		if s.modal_seq == seq then
			close_modal(s)
		end
		s.notice = { tone = "success", text = "Repository mounted in " .. ws }
		select_ws(s, ws, c)
		changed(s, c)
	end)
end

function Store.load_wis(s, cx, live: boolean, selection)
	if s.busy.work_items then return end
	local ctx = context(s)
	local token = begin_op(s, "work_items", if live then "Fetching work items…" else "Reading cached work items…")
	redraw(s, cx)
	local extra = if live then snapshot(selection or {}) else {}
	extra.live = live
	local input = rooted(s, extra)
	s.dev.work_items(input, function(r, c)
		end_op(s, "work_items", token)
		if not current(s, ctx) then return end
		if r.ok then
			s.wis, s.live_selection = r.value, nil
			if s.modal == "live" then close_modal(s) end
		elseif live and r.error.code == "INTERACTION_REQUIRED" then
			local details = r.error.details
			local field = type(details) == "table" and details.field
			local choices, seen = {}, {}
			if field == "provider" or field == "project" then
				local options = if type(details.choices) == "table" then details.choices else {}
				for _, choice in options do
					if type(choice) == "string" and choice ~= "" and not seen[choice] then
						seen[choice] = true
						table.insert(choices, choice)
					end
				end
			end
			if (field == "provider" or field == "project") and #choices > 0 then
				if s.modal ~= "live" then open_modal(s, "live") end
				s.live_selection = { field = field, choices = choices, input = extra }
			else
				fail(s, "work_items", input, "List work items", r.error)
			end
		else
			fail(s, "work_items", input, "List work items", r.error)
		end
		redraw(s, c)
	end)
end

-- One record on a detail screen (`slot` "pr" or "wi"): { key, data?, error?, loading }. An answer for a record no
-- longer shown is dropped.
local function load_detail(s, slot: string, op: string, input, key: string)
	local entry = { key = key, loading = true }
	s[slot] = entry
	s.dev[op](rooted(s, input), function(r, c)
		if s[slot] ~= entry then
			return
		end
		entry.loading = false
		if r.ok then
			entry.data = r.value
		else
			entry.error = r.error
		end
		redraw(s, c)
	end)
end

-- A listed work item's identity is its cache namespace and ID: the same number exists in other tenants and projects.
-- It travels in a `wi` action as "<tenant>|<project>|<id>", the first two with "%" and "|" percent-escaped.
local function escape_part(text: string): string
	return (string.gsub(text, "[%%|]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

function Store.work_item_action_value(w): string?
	if type(w) ~= "table" then return nil end
	local id = w.id
	if type(w.tenant) ~= "string" or w.tenant == "" or type(w.project) ~= "string" or w.project == "" then return nil end
	if type(id) ~= "number" or id < 1 or id % 1 ~= 0 then return nil end
	return escape_part(w.tenant) .. "|" .. escape_part(w.project) .. "|" .. string.format("%d", id)
end

-- The `{ tenant, project, id }` a `wi` action value names; nil for anything else, which is never looked up elsewhere.
function Store.work_item_ref(value: any): { [string]: any }?
	if type(value) ~= "string" then return nil end
	local tenant, project, id = string.match(value, "^([^|]+)|([^|]+)|(%d+)$")
	local n = tonumber(id)
	if not (tenant and project and n and n >= 1) then return nil end
	local function unescape(text: string): string
		return (string.gsub(text, "%%(%x%x)", function(h) return string.char(tonumber(h, 16) :: number) end))
	end
	return { tenant = unescape(tenant), project = unescape(project), id = n }
end

function Store.search(s, cx, query: string)
	local q = string.gsub(query, "^%s*(.-)%s*$", "%1")
	if q == "" then
		return
	end
	local entry = { query = q, loading = true }
	s.search = entry
	show(s, "search")
	s.ask = nil
	redraw(s, cx)
	s.dev.search(rooted(s, { query = q }), function(r, c)
		if s.search ~= entry then
			return
		end
		entry.loading = false
		if r.ok then
			entry.results = r.value
		else
			entry.error = r.error
		end
		redraw(s, c)
	end)
end

-- What each typed question asks; `%s` is the mount.
local ASKS = {
	track = { text = "Branch to track in %s", icon = "git-branch", action = "track" },
	tag = { text = "Tag to pin %s to", icon = "tag", action = "pin" },
	mirror = { text = "Repository to mirror: URL, path or a name dev knows", icon = "copy", action = "mirror" },
	search = { text = "Search the mirrors (qmd)", icon = "search", action = "search" },
}

-- The question `kind` asks: placeholder, icon and the Enter label.
function Store.question(kind: string, mount: string?): { text: string, icon: string, action: string }?
	local q = ASKS[kind]
	if not q then
		return nil
	end
	return { text = string.format(q.text, tostring(mount or "")), icon = q.icon, action = q.action }
end

-- Asks for a typed value: inline in the block (it has fields), a prompt in the window for the sidebar.
function Store.ask(s, cx, kind: string, ws: string?, mount: string?, value: string?)
	if s.env.surface == "block" then
		s.ask = { kind = kind, ws = ws, mount = mount, value = value }
		redraw(s, cx)
		return
	end
	s.env.effect(cx, "ask", { kind = kind, ws = ws, mount = mount, value = value })
end

-- Runs what an asked question was for with the typed `text`.
function Store.answer(s, cx, ask, text: string?)
	local value = string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1")
	s.ask = nil
	if value == "" then
		redraw(s, cx)
		return
	end
	if ask.kind == "track" and ask.ws and ask.mount then
		perform(s, cx, "track", { ws = ask.ws, mount = ask.mount, branch = value }, "Track " .. value .. " in " .. ask.mount)
	elseif ask.kind == "tag" and ask.ws and ask.mount then
		perform(s, cx, "tag", { ws = ask.ws, mount = ask.mount, tag = value }, "Pin " .. ask.mount .. " to " .. value)
	elseif ask.kind == "mirror" then
		perform(s, cx, "mirror_add", { repo = value }, "Add mirror")
	elseif ask.kind == "search" then
		Store.search(s, cx, value)
	else
		redraw(s, cx)
	end
end

-- What a mount holds that a removal could lose, from its status.
local function mount_risk(m): string
	local o = m.observed or {}
	local parts = {}
	if o.exists == false then
		return tostring(m.path) .. ": folder missing"
	end
	if (tonumber(o.modifiedFiles) or 0) > 0 then
		table.insert(parts, tostring(o.modifiedFiles) .. " modified")
	end
	if (tonumber(o.untrackedFiles) or 0) > 0 then
		table.insert(parts, tostring(o.untrackedFiles) .. " untracked")
	end
	if (tonumber(o.aheadCount) or 0) > 0 then
		table.insert(parts, tostring(o.aheadCount) .. " unpushed")
	end
	if #parts == 0 then
		local detail = if o.isDirty then "local changes (count unavailable)"
			elseif o.isDirty == false then "no uncommitted changes reported"
			else "local changes unknown"
		return tostring(m.path) .. ": " .. tostring(m.state or "?") .. ", " .. detail
	end
	return tostring(m.path) .. ": " .. table.concat(parts, " · ") .. " (dev should refuse it)"
end

-- Removes `paths` of `ws` one at a time; the first refusal stops the run and shows dev's message.
local function remove_all(s, cx, ws: string, paths: { string }, root: string?, cwd: string?)
	if s.busy.remove then
		return
	end
	s.failure, s.notice = nil, nil
	local ctx = context(s)
	local token = begin_op(s, "remove", "Removing…")
	local removed = 0
	local function step(i: number, c)
		if i > #paths then
			end_op(s, "remove", token)
			s.notice = { tone = "success", text = string.format("Removed %d mounts from %s", removed, ws) }
			changed(s, c)
			redraw(s, c)
			return
		end
		local mount = paths[i]
		s.busy.remove = string.format("Removing %s (%d of %d)…", mount, i, #paths)
		redraw(s, c)
		local input = { root = root, cwd = cwd, ws = ws, mount = mount }
		s.dev.remove(input, function(r, c2)
			if not current(s, ctx) then
				end_op(s, "remove", token)
				return -- another root now: the run stops here and reports nothing into it
			end
			if r.ok then
				removed += 1
				step(i + 1, c2)
				return
			end
			end_op(s, "remove", token)
			local label = "Remove " .. mount
			if removed > 0 then
				label ..= string.format(" (%d of %d removed before it)", removed, #paths)
			end
			fail(s, "remove", input, label, r.error)
			if removed > 0 then
				changed(s, c2)
			end
			redraw(s, c2)
		end)
	end
	step(1, cx)
end

-- Observations a removal may be reviewed from: read, not failed, not retained from an earlier read.
local function observed_ok(s, st): boolean
	return st ~= nil and not st.loading and not st.error and not st.stale and not s.workspaces_stale
end

-- Both removal confirmations run only while the reviewed root, and the very status entry reviewed, still stand.
local function reviewed_still_valid(s2, c, ctx, ws: string, st): boolean
	if not current(s2, ctx) then
		s2.notice = {
			tone = "warning",
			text = "Workspace root changed; review the mounts again before removing them.",
		}
		redraw(s2, c)
		return false
	end
	if s2.status[ws] ~= st or not observed_ok(s2, st) then
		s2.notice = { tone = "warning", text = "Workspace status changed; refresh and review the mounts again." }
		redraw(s2, c)
		return false
	end
	return true
end

local function confirm_remove_all(s, ws: string)
	local st = s.status[ws]
	if not observed_ok(s, st) then
		s.notice = { tone = "warning", text = "Refresh the workspace status before reviewing removals." }
		return
	end
	local mounts = (st and type(st.data) == "table" and st.data.mounts) or {}
	if #mounts == 0 then
		return
	end
	local ctx = context(s)
	local root = s.active_root -- the reviewed root, not whatever is selected when Confirm is clicked
	local workspace = Store.workspace(s, ws)
	local cwd = workspace and workspace.path
	local lines = {
		"Removes each mount's worktree folder and its entry in ws.md, one at a time.",
		"dev refuses a removal that would lose work; the run stops there and never forces.",
	}
	local paths, commands = {}, {}
	for _, m in mounts do
		table.insert(paths, tostring(m.path))
		table.insert(lines, mount_risk(m))
		table.insert(commands, s.dev.describe("remove", { ws = ws, mount = tostring(m.path) }))
	end
	s.confirm = {
		title = string.format("Remove all %d mounts of %s?", #mounts, ws),
		lines = lines,
		tone = "warning",
		variant = "danger",
		cmd = table.concat(commands, "\n"),
		label = "Remove all mounts of " .. ws,
		run = function(s2, c)
			if reviewed_still_valid(s2, c, ctx, ws, st) then
				remove_all(s2, c, ws, paths, root, cwd)
			end
		end,
	}
end

-- One mount: reviewed from the same fresh observation as the batch, and re-checked when confirmed.
local function confirm_remove(s, ws: string, mount: string)
	local st = s.status[ws]
	if not observed_ok(s, st) then
		s.notice = { tone = "warning", text = "Refresh the workspace status before reviewing removals." }
		return
	end
	local observed = nil
	for _, m in (type(st.data) == "table" and st.data.mounts) or {} do
		if tostring(m.path) == mount then
			observed = m
		end
	end
	if not observed then
		s.notice = { tone = "warning", text = "That mount is not in the latest status; refresh and review again." }
		return
	end
	local ctx = context(s)
	local workspace = Store.workspace(s, ws)
	local input = { root = s.active_root, cwd = workspace and workspace.path, ws = ws, mount = mount }
	local label = "Remove " .. mount
	s.confirm = {
		title = "Remove mount " .. mount .. "?",
		lines = {
			"Removes the worktree folder and its entry in ws.md.",
			"dev refuses when that would discard work; this never forces.",
			mount_risk(observed),
		},
		tone = "warning",
		variant = "danger",
		op = "remove",
		input = input,
		cmd = s.dev.describe("remove", { ws = ws, mount = mount }),
		label = label,
		run = function(s2, c)
			if reviewed_still_valid(s2, c, ctx, ws, st) then
				perform(s2, c, "remove", input, label)
			end
		end,
	}
end

-- Every click from either surface lands here as `act` plus an optional `value`.
function Store.dispatch(s, cx, act: string, value: any)
	local env = s.env
	if act == "refresh" then
		Store.refresh(s, cx, true)
		return
	elseif act == "home" or act == "back" then
		if act == "back" and s.screen == "pr" then
			show(s, "prs")
		elseif act == "back" and s.screen == "wi" then
			show(s, "wis")
		elseif act == "back" and s.screen == "mirror" then
			show(s, "mirrors")
		else
			select_ws(s, nil)
		end
		s.ask = nil
	elseif act == "ws" then
		select_ws(s, value, cx)
	elseif act == "mirrors" or act == "roots" then
		show(s, act)
	elseif act == "prs" then
		show(s, "prs")
		if s.prs == nil then
			Store.load_prs(s, cx, false)
		end
	elseif act == "prs.filters" then
		open_modal(s, "prsfilters")
	elseif act == "prs.query" then
		commit_pr_query(s, cx, value)
	elseif act == "prs.scope" and (value == "mine" or value == "all") then
		local query = snapshot(s.pr_query)
		query.scope = value
		commit_pr_query(s, cx, query)
	elseif act == "prs.filters.reset" then
		commit_pr_query(s, cx, { scope = "mine", status = "open" })
	elseif act == "prs.live" then
		Store.load_prs(s, cx, true)
		return
	elseif act == "root" and value then
		-- Picking the default root forgets the choice, so a later change of default is followed.
		local entry = Store.root_entry(s, value)
		choose_root(if entry and entry.isDefault then nil else value)
		clear_root(s)
		Store.refresh(s, cx, true)
		env.effect(cx, "refresh", {})
		return
	elseif act == "presence" and value then
		local w = Store.workspace(s, value)
		if w then
			env.effect(cx, "presence", { name = w.name, path = w.path })
		end
		return
	elseif act == "open" and value then
		local w = Store.workspace(s, value)
		if w then
			env.effect(cx, "open", { name = w.name, path = w.path })
		end
		return
	elseif act == "start" and value then
		mutate(s, cx, "start", { ws = value }, "Start OMP", function(v, c)
			s.notice = { tone = "success", text = if v.reused then "OMP focused in HerdR" else "OMP started in HerdR" }
			redraw(s, c)
		end)
		return
	elseif act == "copy" and value then
		env.effect(cx, "copy", { text = value })
		return
	elseif act == "manifest" and value then
		local w = Store.workspace(s, value)
		if w then
			env.effect(cx, "edit", { path = tostring(w.path) .. (if string.find(tostring(w.path), "\\") then "\\" else "/") .. "ws.md" })
		end
		return
	elseif act == "describe" and value then
		-- The window edits it: a prompt, then ws.md through the live document (see DevCli.set_description).
		local w = Store.workspace(s, value)
		if w then
			env.effect(cx, "describe", { ws = w.name, path = tostring(w.path), text = tostring(w.description or "") })
		end
		return
	elseif act == "settings" then
		env.effect(cx, "settings", {})
		return
	elseif act == "update" and value then
		plan_update(s, cx, value)
		return
	elseif act == "apply" and s.plan then
		apply_update(s, cx, value)
		return
	elseif act == "plan.close" then
		s.plan, s.planning = nil, nil
	elseif act == "git" and value then
		env.effect(cx, "git", { path = value })
		return
	elseif act == "lock" or act == "unlock" then
		local ws, mount = split_pair(value)
		if ws and mount then
			perform(s, cx, act, { ws = ws, mount = mount }, (if act == "lock" then "Lock " else "Unlock ") .. mount)
		end
		return
	elseif act == "remove" then
		local ws, mount = split_pair(value)
		if ws and mount then
			confirm_remove(s, ws, mount)
		end
	elseif act == "mirror.sync" then
		if value == nil or value == "" then
			perform(s, cx, "sync_mirrors", {}, "Sync all mirrors")
			return
		end
		-- One mirror: never fall through to syncing all of them.
		local m = nil
		for _, x in s.mirrors do
			if x.name == value then
				m = x
			end
		end
		if m and m.linked == false then
			s.notice = nil
			s.failure = {
				op = "sync_mirrors",
				input = {},
				label = "Sync mirror " .. value,
				error = {
					code = "MIRROR_ADMIN_MISSING",
					message = "dev cannot sync this mirror: its repository under .dev/repos is gone, so the checkout has no branch. "
						.. "Its files are untouched: copy anything you need from it and move the folder aside first.",
					nextStep = "dev mirror add <repository> --branch <branch>",
					detail = tostring(m.path),
					details = {},
				},
				remedies = {},
			}
		else
			perform(s, cx, "sync_mirrors", { source = if m and m.sourceUrl then m.sourceUrl else value }, "Sync mirror " .. value)
			return
		end
	elseif act == "sync.data" then
		perform(s, cx, "sync_providers", {}, "Sync from providers")
		return
	elseif act == "pr.checkout" and value then
		mutate(s, cx, "checkout_pr", { ref = value }, "Check out pull request", function(_, c)
			s.notice = { tone = "success", text = "Pull request checked out as a workspace" }
			s.env.effect(c, "refresh", {})
			s.after_load = function(c2)
				select_ws(s, newest(s), c2)
			end
			Store.refresh(s, c)
		end)
		return
	elseif act == "worksets" then
		show(s, "worksets")
		Store.load_worksets(s, cx)
	elseif act == "worksets.refresh" then
		Store.load_worksets(s, cx)
	elseif act == "workset.new" then
		open_modal(s, "workset")
		s.workset_draft = { name = "", definition = { members = {} } }
		Store.load_sources(s, cx)
	elseif act == "workset.edit" and value then
		open_modal(s, "workset")
		Store.load_workset(s, cx, value)
		Store.load_sources(s, cx)
	elseif act == "workset.save" and type(value) == "table" then
		Store.save_workset(s, cx, value)
	elseif act == "workset.create" and value then
		open_modal(s, "create")
		s.modal_workset = value
		Store.load_sources(s, cx)
	elseif act == "create" then
		open_modal(s, "create")
		Store.load_sources(s, cx)
	elseif act == "create.preview" and type(value) == "table" then
		Store.preview_workspace(s, cx, value)
	elseif act == "create.commit" then
		Store.commit_workspace(s, cx)
	elseif act == "create.back" then
		Store.invalidate_creation(s)
	elseif act == "add" and value then
		if not Store.workspace(s, value) then return end
		open_modal(s, "add", value)
		Store.load_sources(s, cx)
	elseif act == "modal.close" then
		close_modal(s)
	elseif act == "page" and value then
		local collection, n = string.match(value, "^(%a+):(%d+)$")
		if not (collection and s.pages[collection] ~= nil and tonumber(n) :: number >= 1) then
			return
		end
		s.pages[collection] = tonumber(n)
	elseif act == "mirror.browse" and value then
		local m = find_mirror(s, value)
		if not (m and type(m.path) == "string" and m.path ~= "") then
			return
		end
		local b = new_browser(m.path, m.name, true)
		s.browse = b
		s.screen = "mirror"
		read_open(s, cx, b)
	elseif act == "files.toggle" and value then
		if not files_toggle(s, cx, value) then
			return
		end
	elseif act == "files.page" and value then
		if not files_page(s, cx, value) then
			return
		end
	elseif act == "files.open" and value then
		files_open(s, cx, value)
		return
	elseif act == "ws.tab" and s.selected and (value == "overview" or value == "repositories" or value == "files") then
		s.workspace_tabs[s.selected] = value
	elseif act == "check" and value then
		Store.check(s, cx, value, { refresh = true })
		return
	elseif (act == "track" or act == "tag") and value then
		local ws, mount = split_pair(value)
		if ws and mount then
			Store.ask(s, cx, act, ws, mount, nil)
		end
		return
	elseif act == "mirror.add" then
		Store.ask(s, cx, "mirror", nil, nil, nil)
		return
	elseif act == "search" then
		if value and value ~= "" then
			Store.search(s, cx, value)
		else
			Store.ask(s, cx, "search", nil, nil, s.search and s.search.query)
		end
		return
	elseif act == "ask.cancel" then
		s.ask = nil
	elseif act == "hit" and value and s.search and s.search.results then
		local hit = s.search.results[tonumber(value) or 0]
		if hit then
			local file = tostring(hit.file or "")
			if string.match(file, "^%a+://") then
				-- qmd could not place it on disk (the index is older than the mirror): its id is all there is.
				env.effect(cx, "copy", { text = file })
			else
				env.effect(cx, "edit", { path = file, line = tostring(tonumber(hit.line) or 1) })
			end
		end
		return
	elseif act == "wis" then
		show(s, "wis")
		if s.wis == nil then
			Store.load_wis(s, cx, false)
		end
	elseif act == "wis.live" then
		Store.load_wis(s, cx, true)
		return
	elseif act == "live.select" and type(value) == "string" and s.live_selection then
		local selection = s.live_selection
		local allowed = false
		for _, choice in selection.choices do
			if choice == value then allowed = true break end
		end
		if not allowed or (selection.field ~= "provider" and selection.field ~= "project") then return end
		local input = snapshot(selection.input or {})
		input[selection.field] = value
		Store.load_wis(s, cx, true, input)
		return
	elseif act == "wi" and value then
		local ref = Store.work_item_ref(value)
		if not ref then return end
		show(s, "wi")
		load_detail(s, "wi", "work_item", ref, tostring(ref.id))
	elseif act == "pr" and value then
		show(s, "pr")
		load_detail(s, "pr", "pull_request", { ref = value }, value)
	elseif act == "url" and value then
		env.effect(cx, "url", { url = value })
		return
	elseif act == "remove.all" and value then
		confirm_remove_all(s, value)
	elseif act == "remedy" and value and s.failure then
		local f = s.failure
		local remedy = f.remedies[tonumber(value) or 0]
		if remedy then
			if remedy.kind == "refresh" then
				s.failure = nil
				Store.refresh(s, cx, true)
				return
			elseif remedy.kind == "select" then
				s.failure = nil
				select_ws(s, remedy.value, cx)
			elseif remedy.kind == "run" and remedy.op and remedy.confirm then
				s.confirm = {
					title = remedy.confirm.title,
					lines = remedy.confirm.lines,
					tone = remedy.confirm.tone,
					variant = "primary",
					op = remedy.op,
					input = remedy.input,
					label = f.label,
				}
			elseif remedy.kind == "run" and remedy.op then
				perform(s, cx, remedy.op, remedy.input, f.label)
				return
			end
		end
	elseif act == "confirm.yes" and s.confirm then
		local c = s.confirm
		s.confirm = nil
		if c.run then
			c.run(s, cx)
		else
			perform(s, cx, c.op, c.input, c.label)
		end
		return
	elseif act == "confirm.no" then
		s.confirm = nil
	elseif act == "dismiss" then
		s.failure = nil
		s.notice = nil
	else
		return
	end
	redraw(s, cx)
end

-- Health of a workspace from its status: label and tone.
local STATE_RANK = {
	missing = { 5, "error", "missing" },
	diverged = { 4, "error", "diverged" },
	dirty = { 3, "warning", "dirty" },
	wrong_revision = { 3, "warning", "wrong revision" },
	behind = { 2, "info", "behind" },
	ahead = { 1, "info", "ahead" },
}

function Store.health(s, w): (string, string)
	local mounts = tonumber(w.mountCount) or 0
	if mounts == 0 then
		return "empty", "muted"
	end
	local st = s.status[w.name]
	if not st then
		return "unchecked", "muted"
	end
	if st.loading then
		return "checking", "muted"
	end
	if st.stale and st.data then return "stale", "warning" end
	if st.error then
		return "error", "error"
	end
	local data = st.data
	if type(data) ~= "table" then
		return "?", "muted"
	end
	local worst, label, tone, count = 0, "clean", "success", 0
	for _, m in (if type(data.mounts) == "table" then data.mounts else {}) do
		local r = STATE_RANK[m.state]
		if r then
			count += 1
			if r[1] > worst then
				worst, tone, label = r[1], r[2], r[3]
			end
		end
	end
	if count > 1 then
		label = label .. " +" .. tostring(count - 1)
	end
	return label, tone
end

return Store
