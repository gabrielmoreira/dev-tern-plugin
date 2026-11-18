--!nonstrict
-- Integration tests without UI: the plugin's real modules run under Lune against the real dev executable, in a
-- throwaway HOME with two registered roots. Run from the plugin folder:  lune run test/run.luau
-- Nothing touches the user's own ~/.dev.toml or roots.

local process = require("@lune/process")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local task = require("@lune/task")
local Shim = require("./shim")

local PLUGIN = string.gsub(process.cwd, "\\", "/")
PLUGIN = string.gsub(PLUGIN, "/$", "")
local TMP = PLUGIN .. "/.local/it-" .. tostring(os.time())
local HOME = TMP .. "/home"
local ROOT_A = TMP .. "/root-alpha"
local ROOT_B = TMP .. "/root-beta"
local SRC = TMP .. "/src/lib"

local failures, passed = {}, 0
local function check(name: string, cond: any, detail: any?)
	if cond then
		passed += 1
		print("  ok   " .. name)
	else
		table.insert(failures, name)
		print("  FAIL " .. name .. (if detail ~= nil then "\n       " .. tostring(detail) else ""))
	end
end
local function section(name: string)
	print("\n## " .. name)
end

-- Setup ------------------------------------------------------------------------------------------------------

fs.writeDir(HOME)
fs.writeDir(TMP .. "/src")
Shim.extra_env = { HOME = HOME, USERPROFILE = HOME, DEV_ROOT = "", NO_COLOR = "1" }

local Dev = Shim.load(PLUGIN .. "/devcli.luau")
local DEV = Dev.binary()
print("dev binary: " .. DEV)

local function sh(program: string, args: { string }, cwd: string?)
	local r = process.exec(program, args, { cwd = cwd, env = Shim.extra_env })
	if not r.ok then
		error(program .. " " .. table.concat(args, " ") .. " failed:\n" .. r.stdout .. r.stderr)
	end
	return r.stdout
end
local function dev(args: { string })
	local full = table.clone(args)
	table.insert(full, "--json")
	table.insert(full, "--non-interactive")
	local out = sh(DEV, full)
	return if string.match(out, "^%s*$") then nil else serde.decode("json", out)
end

dev({ "init", ROOT_A, "--alias", "alpha" })
dev({ "init", ROOT_B, "--alias", "beta" })
dev({ "root", "add", ROOT_A, "--alias", "alpha", "--default", "--force" })
dev({ "ws", "init", "beta-only", "--root", ROOT_B })
dev({ "ws", "init", "alpha-seed", "--desc", "seed workspace", "--root", ROOT_A })

fs.writeDir(SRC)
sh("git", { "init", "-q", "-b", "main" }, SRC)
fs.writeFile(SRC .. "/README.md", "lib\n")
sh("git", { "-c", "user.name=t", "-c", "user.email=t@t", "add", "." }, SRC)
sh("git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init" }, SRC)
sh("git", { "branch", "ux-topic" }, SRC)
sh("git", { "tag", "ux-v1" }, SRC)

local roots = dev({ "roots" })
print("roots: " .. serde.encode("json", roots))

-- Helpers ----------------------------------------------------------------------------------------------------

local Store = Shim.load(PLUGIN .. "/store.luau")
local View = Shim.load(PLUGIN .. "/view.luau")

-- Every visible string in a node tree, joined.
local function texts(node, out)
	out = out or {}
	if type(node) ~= "table" then
		return out
	end
	local p = node.p or {}
	for _, key in { "spans", "head", "label" } do
		if type(p[key]) == "table" then
			for _, s in p[key] do
				if type(s) == "table" and s.t then
					table.insert(out, s.t)
				end
			end
		end
	end
	for _, key in { "text", "title" } do
		if type(p[key]) == "string" then
			table.insert(out, p[key])
		end
	end
	for _, c in node.c or {} do
		texts(c, out)
	end
	return out
end
local function screen_text(s, opts)
	local main, dock = View.render(s, opts or {})
	return table.concat(texts(main), "\n") .. "\n" .. table.concat(texts(dock), "\n"), main
end
local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

-- Click actions present in the tree.
local function actions(node, out)
	out = out or {}
	if type(node) ~= "table" then
		return out
	end
	local p = node.p or {}
	if type(p.actions) == "table" and type(p.actions.click) == "string" then
		out[p.actions.click] = true
	end
	for _, c in node.c or {} do
		actions(c, out)
	end
	return out
end

-- Sibling keys must be unique, or Tern's keyed patches collide.
local function duplicate_keys(node, path, out)
	out = out or {}
	path = path or "root"
	if type(node) ~= "table" then
		return out
	end
	local seen = {}
	for _, c in node.c or {} do
		local k = type(c) == "table" and c.p and c.p.key
		if k then
			if seen[k] then
				table.insert(out, path .. "." .. tostring(k))
			end
			seen[k] = true
		end
		duplicate_keys(c, path .. "." .. tostring(k or c.k), out)
	end
	return out
end
-- Props of the first node whose click is `action`.
local function button_props(node, action: string)
	if type(node) ~= "table" then
		return nil
	end
	local p = node.p or {}
	if type(p.actions) == "table" and p.actions.click == action then
		return p
	end
	for _, c in node.c or {} do
		local found = button_props(c, action)
		if found then
			return found
		end
	end
	return nil
end

local function has_kind(node, kind: string): boolean
	if type(node) ~= "table" then
		return false
	end
	if node.k == kind then
		return true
	end
	for _, c in node.c or {} do
		if has_kind(c, kind) then
			return true
		end
	end
	return false
end

-- A store wired like the block's, recording redraws and effects.
local function new_store(surface: string?)
	local rec = { redraws = 0, effects = {} }
	local s = Store.new({
		surface = surface or "block",
		dev = Dev,
		redraw = function()
			rec.redraws += 1
		end,
		effect = function(_, kind, data)
			table.insert(rec.effects, { kind = kind, data = data })
		end,
	})
	return s, rec
end

-- Clicks an action string the way Tern does: `name=value` splits at the first `=`.
local function click(s, action: string)
	local name, value = string.match(action, "^([^=]+)=(.*)$")
	Store.dispatch(s, nil, name or action, if name then value else nil)
end

local function names(s): { [string]: boolean }
	local out = {}
	for _, w in s.workspaces do
		out[w.name] = true
	end
	return out
end

-- Tests ------------------------------------------------------------------------------------------------------

section("decode units")
do
	local a = Dev.decode({ status = 0, stdout = '[{"name":"x"}]', stderr = "", timed_out = false })
	check("success decodes JSON", a.ok and a.value[1].name == "x")
	local b = Dev.decode({ status = 0, stdout = "", stderr = "", timed_out = false })
	check("empty stdout is ok with nil value", b.ok and b.value == nil)
	local c = Dev.decode({ status = 0, stdout = "hello\nworld", stderr = "", timed_out = false })
	check("non-JSON stdout is BAD_OUTPUT", not c.ok and c.error.code == "BAD_OUTPUT" and has(c.error.detail, "hello"))
	local d = Dev.decode({
		status = 3,
		stdout = "",
		stderr = 'warn: x\n{"error":{"code":"DIRTY_WORKTREE","message":"m","nextStep":"git status","details":{"a":1}}}\n',
		timed_out = false,
	})
	check("error envelope on stderr", not d.ok and d.error.code == "DIRTY_WORKTREE" and d.error.nextStep == "git status" and d.error.details.a == 1)
	local d2 = Dev.decode({
		status = 3,
		stdout = "",
		stderr = '{"error":{"code":"WORKSPACE_ALREADY_EXISTS","message":"m","name":"dup","path":"C:/x"}}',
		timed_out = false,
	})
	check("context beside code lands in details", d2.error.details.name == "dup" and d2.error.details.path == "C:/x")
	local e = Dev.decode({ status = -1, stdout = "", stderr = "", timed_out = true })
	check("timeout", not e.ok and e.error.code == "TIMEOUT")
	local f = Dev.decode({ status = 1, stdout = "", stderr = "panic: boom", timed_out = false })
	check("exit without envelope is FAILED with detail", not f.ok and f.error.code == "FAILED" and has(f.error.detail, "boom"))
end

section("the store depends on the dev port, not on the CLI")
do
	-- A stand-in port answering like a future dev API would; no process runs.
	local calls = {}
	local function answer(value)
		return function(input, done)
			table.insert(calls, input)
			done({ ok = true, value = value }, nil)
		end
	end
	local fake = {
		roots = answer({ { alias = "api", path = "C:/api-root", isDefault = true } }),
		current = answer({ root = "C:/api-root", source = "global" }),
		workspaces = answer({ { name = "from-api", path = "C:/api-root/ws/from-api", mountCount = 0 } }),
		mirrors = answer({}),
		folders = function()
			return {}
		end,
		describe = function(op)
			return "api " .. op
		end,
	}
	local runs_before = #Shim.runs
	local f = Store.new({ surface = "block", dev = fake, redraw = function() end, effect = function() end })
	Store.refresh(f, nil)
	check("lists what the port answers", f.loading == false and names(f)["from-api"])
	check("reads go to the port's root", calls[3] and calls[3].root == "C:/api-root")
	check("no dev process ran", #Shim.runs == runs_before)
	local t = screen_text(f)
	check("view renders from it", has(t, "from-api") and has(t, "api"), t)
end

section("refresh reads the default root")
local s, rec = new_store()
Store.refresh(s, nil)
check("loading set while dev runs", s.loading == true)
Shim.settle()
check("loading cleared", s.loading == false, string.format("pending=%d reload=%s runs=%d", Shim.pending, tostring(s.reload), #Shim.runs))
check("no load error", s.load_error == nil, s.load_error and serde.encode("json", s.load_error))
check("active root is the default (alpha)", Store.norm(s.active_root) == Store.norm(ROOT_A), s.active_root)
check("roots listed (2)", #s.roots == 2, #s.roots)
check("lists alpha's workspace", names(s)["alpha-seed"], serde.encode("json", s.workspaces))
check("does not list beta's workspace", not names(s)["beta-only"])
check("workspaces are a plain table (sortable)", pcall(table.sort, s.workspaces, function(a, b)
	return a.name < b.name
end))
check("empty workspace remains directly reachable", View.order(s)[1] == "alpha-seed")
local text, main = screen_text(s)
check("home shows the workspace", has(text, "alpha-seed") and has(text, "seed workspace"), text)
check("header shows root alias", has(text, "alpha"), text)
check("home has no progress after load", not has(text, "Reading workspaces"), text)
check("refresh button present", actions(main)["refresh"])
check("no duplicate sibling keys", #duplicate_keys(main) == 0, table.concat(duplicate_keys(main), ", "))
check("sidebar view has no input node", not has_kind(main, "input"))
check("redraws happened", rec.redraws > 0)

section("refresh button: forced, coalesced, and recovering from a plugin error")
do
	local runs_before = #Shim.runs
	Store.refresh(s, nil) -- automatic
	Store.refresh(s, nil) -- automatic while loading: coalesced
	check("second automatic refresh coalesced", s.reload == true)
	click(s, "refresh") -- a person clicked: starts over
	check("click restarts at once", s.loading == true and s.reload == false)
	Shim.settle()
	check("forced refresh finished", s.loading == false and s.load_error == nil)
	check("workspaces still listed", names(s)["alpha-seed"])
	check("dev was called again", #Shim.runs > runs_before)

	-- A redraw that throws mid-refresh must not leave `loading` stuck.
	local s2 = new_store()
	local boom = 0
	s2.env.redraw = function()
		boom += 1
		if boom == 2 then
			error("render exploded")
		end
	end
	Store.refresh(s2, nil)
	Shim.settle()
	check("refresh after a plugin error is not stuck", s2.loading == false)
	s2.env.redraw = function() end
	click(s2, "refresh")
	Shim.settle()
	check("next refresh works", s2.loading == false and names(s2)["alpha-seed"], s2.load_error and serde.encode("json", s2.load_error))

	-- Real Tern tags arrays; a callback mutating them used to throw and freeze the list.
	local arr = Shim.tern.json.decode('[{"name":"a"}]')
	check("shim tags arrays like Tern", not pcall(table.clone, arr))
end

section("statuses load for workspaces with mounts")
do
	-- Mount the local repo through the store, as the add form does.
	Store.add_repo(s, nil, "alpha-seed", { repo = SRC, branch = "", readonly = false })
	check("busy marker while adding", s.busy.add ~= nil)
	Shim.settle()
	check("add succeeded", s.failure == nil, s.failure and serde.encode("json", s.failure.error))
	local w = Store.workspace(s, "alpha-seed")
	check("mount counted", w and tonumber(w.mountCount) == 1, w and w.mountCount)
	local st = s.status["alpha-seed"]
	check("status loaded", st and st.data and not st.loading, st and serde.encode("json", st))
	local label = Store.health(s, w)
	check("health is clean", label == "clean", label)
	click(s, "ws=alpha-seed")
	click(s, "ws.tab=repositories")
	local t = screen_text(s)
	check("workspace screen shows the mount", has(t, "lib"), t)
	local extra = s.folders["alpha-seed"]
	check("a mount is not listed as another folder", extra and #extra == 0, extra and serde.encode("json", extra))
end

section("lock / unlock / update / remove")
do
	local function mount_name(): string?
		local st = s.status["alpha-seed"]
		local m = st and st.data and st.data.mounts and st.data.mounts[1]
		return m and (m.name or m.path or m.mount)
	end
	local mount = mount_name()
	check("mount name known", mount ~= nil, s.status["alpha-seed"] and serde.encode("json", s.status["alpha-seed"].data))
	mount = mount or "lib"

	click(s, "lock=alpha-seed|" .. mount)
	Shim.settle()
	check("lock ok", s.failure == nil and s.notice and has(s.notice.text, "Lock"), s.failure and serde.encode("json", s.failure.error))
	click(s, "unlock=alpha-seed|" .. mount)
	Shim.settle()
	check("unlock ok", s.failure == nil, s.failure and serde.encode("json", s.failure.error))

	click(s, "update=alpha-seed")
	Shim.settle()
	check("update plan loaded", s.plan and s.plan.ws == "alpha-seed", s.failure and serde.encode("json", s.failure.error))
	local t, main = screen_text(s)
	check("plan offers apply", actions(main)["apply"] ~= nil or next(actions(main)) ~= nil, t)
	click(s, "apply")
	Shim.settle()
	check("update applied", s.failure == nil and s.plan == nil, s.failure and serde.encode("json", s.failure.error))

	-- Dirty mount: the plan shows it; applying is refused or skips it; autostash only behind a confirmation;
	-- remove is refused (UNSAFE_REMOVE) with no forcing remedy; once clean, remove works.
	local wpath = Store.workspace(s, "alpha-seed").path
	local mount_dir = string.gsub(wpath, "\\", "/") .. "/" .. mount
	check("mount folder exists", fs.isDir(mount_dir), mount_dir)
	fs.writeFile(mount_dir .. "/README.md", "edited\n")
	click(s, "update=alpha-seed")
	Shim.settle()
	local pt = screen_text(s)
	check("plan mentions uncommitted changes", has(pt, "uncommitted") or has(pt, "dirty"), pt)
	click(s, "apply")
	Shim.settle()
	if s.failure then
		print("       apply while dirty refused: " .. s.failure.error.code)
		local idx = nil
		for i, r in s.failure.remedies do
			if has(r.label, "autostash") then
				idx = i
			end
		end
		check("dirty refusal offers autostash", s.failure.error.code == "DIRTY_WORKTREE" and idx ~= nil, serde.encode("json", s.failure.error))
		if idx then
			click(s, "remedy=" .. idx)
			check("autostash asks first", s.confirm ~= nil and s.confirm.op == "update" and has(Dev.describe(s.confirm.op, s.confirm.input), "--autostash"))
			click(s, "confirm.yes")
			Shim.settle()
			check("autostash update ok", s.failure == nil, s.failure and serde.encode("json", s.failure.error))
		end
	else
		print("       apply while dirty: " .. tostring(s.notice and s.notice.sub))
		check("dirty mount skipped, not changed", s.notice and has(s.notice.sub or "", "skipped"), s.notice and s.notice.sub)
	end
	check("local edit kept", fs.readFile(mount_dir .. "/README.md") == "edited\n")

	click(s, "remove=alpha-seed|" .. mount)
	check("remove asks first", s.confirm ~= nil and s.confirm.op == "remove")
	check("remove never passes --force", not has(Dev.describe(s.confirm.op, s.confirm.input), "--force"))
	click(s, "confirm.no")
	check("cancel clears the confirmation", s.confirm == nil)
	click(s, "remove=alpha-seed|" .. mount)
	click(s, "confirm.yes")
	Shim.settle()
	check("dirty remove refused by dev", s.failure and s.failure.error.code == "UNSAFE_REMOVE", s.failure and s.failure.error.code)
	local forcing = false
	for _, r in (s.failure and s.failure.remedies or {}) do
		forcing = forcing or (r.op ~= nil and has(Dev.describe(r.op, r.input), "--force"))
	end
	check("no remedy forces removal", not forcing)
	check("worktree still there", fs.isDir(mount_dir))
	click(s, "dismiss")

	sh("git", { "checkout", "--", "." }, mount_dir)
	sh("git", { "stash", "clear" }, mount_dir)
	click(s, "remove=alpha-seed|" .. mount)
	click(s, "confirm.yes")
	Shim.settle()
	check("clean remove ok", s.failure == nil, s.failure and serde.encode("json", s.failure.error))
	local w = Store.workspace(s, "alpha-seed")
	check("mount gone", w and (tonumber(w.mountCount) or 0) == 0, w and w.mountCount)
end

local function create_reviewed(form)
	Store.dispatch(s, nil, "create")
	Store.preview_workspace(s, nil, form)
	Shim.settle()
	if s.creation and not s.creation.data.exists then
		Store.commit_workspace(s, nil)
		Shim.settle()
	end
end

section("create workspace and refusals")
do
	create_reviewed({ source = "empty", name = "from-plugin", desc = "made by the test" })
	Shim.settle()
	check("create ok", s.failure == nil, s.failure and serde.encode("json", s.failure.error))
	check("new workspace listed", names(s)["from-plugin"])
	check("new workspace selected", s.selected == "from-plugin" and s.screen == "ws", tostring(s.selected) .. " " .. s.screen)

	-- Existing names are now detected by review, before any mutation.
	click(s, "home")
	create_reviewed({ source = "empty", name = "from-plugin", desc = "" })
	check("review identifies the existing workspace", s.creation and s.creation.data.exists)
	check("existing workspace cannot be created again", not Store.commit_workspace(s, nil))
	Store.dispatch(s, nil, "modal.close")
	click(s, "ws=from-plugin")
	check("the existing workspace can be inspected", s.selected == "from-plugin" and s.screen == "ws")

	click(s, "home")
	local before = fs.readFile(ROOT_A .. "/ws/from-plugin/ws.md")
	create_reviewed({ source = "empty", name = "from-plugin", desc = "something else" })
	check("conflicting name is detected before mutation", s.creation and s.creation.data.exists)
	check("conflicting review cannot commit", not Store.commit_workspace(s, nil))
	check("existing workspace description remains byte-identical", fs.readFile(ROOT_A .. "/ws/from-plugin/ws.md") == before)
	Store.dispatch(s, nil, "modal.close")

	click(s, "update=no-such-workspace")
	Shim.settle()
	check("unknown workspace refused", s.failure ~= nil, "no failure")
	if s.failure then
		print("       code: " .. tostring(s.failure.error.code))
	end
	click(s, "dismiss")

	Store.add_repo(s, nil, "from-plugin", { repo = TMP .. "/does-not-exist", branch = "", readonly = false })
	Shim.settle()
	check("bad repository refused", s.failure ~= nil)
	if s.failure then
		print("       code: " .. tostring(s.failure.error.code))
	end
	click(s, "dismiss")
end

section("ws.md description rewrite")
do
	local folded = "---\nversion: 1\nname: x\ndescription: Eu quero\n  continuar aqui\n\n  e aqui\nmounts: []\n---\n\n# Workspace: x\ndescription: not frontmatter\n"
	local expected = "---\nversion: 1\nname: x\ndescription: \"novo\"\nmounts: []\n---\n\n# Workspace: x\ndescription: not frontmatter\n"
	local out = Dev.with_description(folded, "  novo \n")
	check("replaces a folded value whole, body untouched", out == expected, out)
	local crlf = (string.gsub(folded, "\n", "\r\n"))
	check("keeps CRLF line endings", Dev.with_description(crlf, "novo") == (string.gsub(expected, "\n", "\r\n")))
	check("inserts after name: when absent", Dev.with_description("---\nname: x\nmounts: []\n---\n", "d") == "---\nname: x\ndescription: \"d\"\nmounts: []\n---\n")
	local none, why = Dev.with_description("# no frontmatter\n", "d")
	check("refuses a file without frontmatter", none == nil and why ~= nil, why)
end

section("empty workspace: update plan, other folders, description")
do
	click(s, "ws=from-plugin")
	local w = Store.workspace(s, "from-plugin")
	local _, main = screen_text(s)
	local up = button_props(main, "update=from-plugin")
	check("Update is disabled with no repositories", up and up.disabled ~= nil, up and serde.encode("json", up))
	click(s, "update=from-plugin")
	Shim.settle()
	local t, main2 = screen_text(s)
	local acts = actions(main2)
	check("empty plan says there is nothing to update", s.plan and has(t, "nothing to update"), t)
	check("empty plan offers Add repo, not Apply", acts["add=from-plugin"] and not acts.apply, serde.encode("json", acts))
	click(s, "plan.close")

	fs.writeDir(w.path .. "/notes")
	fs.writeDir(w.path .. "/local-repo")
	sh("git", { "init", "-q" }, w.path .. "/local-repo")
	fs.writeFile(w.path .. "/loose.txt", "x")
	local function commit(dir: string, file: string)
		fs.writeFile(dir .. "/" .. file, file)
		sh("git", { "add", file }, dir)
		sh("git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", file }, dir)
	end
	fs.writeDir(w.path .. "/solo-repo")
	sh("git", { "init", "-q" }, w.path .. "/solo-repo")
	commit(w.path .. "/solo-repo", "a.txt")
	sh("git", { "clone", "-q", SRC, w.path .. "/ahead-repo" })
	commit(w.path .. "/ahead-repo", "new.txt")
	fs.writeFile(w.path .. "/ahead-repo/scratch.txt", "x")
	sh("git", { "clone", "-q", SRC, w.path .. "/synced-repo" })
	Store.refresh(s, nil, true)
	Shim.settle()
	click(s, "ws.tab=repositories")
	local ft = screen_text(s)
	local found = {}
	for _, f in s.folders["from-plugin"] or {} do
		found[f.name] = f.git
	end
	check("folders ws.md does not list are shown", has(ft, "OTHER FOLDERS") and found.notes == false and found["local-repo"] == true, ft)
	check("plain folder told apart from a git repository", has(ft, "plain folder · not in ws.md"), ft)
	check("files and .local are not listed", found["loose.txt"] == nil and found[".local"] == nil, serde.encode("json", found))
	check("repository with no commits", has(ft, "git repository · nothing committed"), ft)
	check("repository with commits and no remote is local only", has(ft, "git repository · local only, no remote"), ft)
	check("unpushed commits and uncommitted changes counted", has(ft, "1 commit not pushed · 1 uncommitted change"), ft)
	check("repository matching its upstream has nothing unpushed", has(ft, "git repository · nothing unpushed · not in ws.md"), ft)
	sh("git", { "remote", "add", "origin", "https://someone:s3cret-token@example.com/me/solo.git" }, w.path .. "/solo-repo")
	Store.refresh(s, nil, true)
	Shim.settle()
	local solo = nil
	for _, f in s.folders["from-plugin"] or {} do
		if f.name == "solo-repo" then
			solo = f
		end
	end
	local _, solo_main = screen_text(s)
	local tree = serde.encode("json", solo_main)
	check("remote shown without its credentials", solo and solo.repo and solo.repo.remote ~= nil and has(tree, "https://example.com/me/solo.git") and not has(tree, "s3cret-token"), solo and serde.encode("json", solo))

	click(s, "update=from-plugin")
	Shim.settle()
	local pt = screen_text(s)
	check("empty plan names the folders dev does not track", has(pt, "nothing to update") and has(pt, "local-repo\n  git repository · nothing committed") and has(pt, "solo-repo\n  git repository · branch ") and has(pt, " not pushed"), pt)
	click(s, "plan.close")

	click(s, "describe=from-plugin")
	local d = rec.effects[#rec.effects]
	check("describe hands the current text to the window", d and d.kind == "describe" and d.data.ws == "from-plugin" and d.data.text == "made by the test", d and serde.encode("json", d))

	click(s, "manifest=from-plugin")
	local edit = rec.effects[#rec.effects]
	check("ws.md opens through the edit effect", edit and edit.kind == "edit" and has(edit.data.path, "from-plugin") and has(edit.data.path, "ws.md"), edit and serde.encode("json", edit))
	click(s, "home")
end

section("mount revisions and safe batch removal")
do
	create_reviewed({ source = "empty", name = "ux-batch" })
	Shim.settle()
	local middle_source, last_source = TMP .. "/src/middle", TMP .. "/src/last"
	sh("git", { "clone", "-q", SRC, middle_source })
	sh("git", { "clone", "-q", SRC, last_source })
	for _, item in { { "first", SRC }, { "middle", middle_source }, { "last", last_source } } do
		Store.add_repo(s, nil, "ux-batch", { repo = item[2], path = item[1] })
		Shim.settle()
	end
	local ws = Store.workspace(s, "ux-batch")
	local base = string.gsub(ws.path, "\\", "/")
	check("explicit mount names create separate folders", fs.isDir(base .. "/first") and fs.isDir(base .. "/middle") and fs.isDir(base .. "/last"))
	Store.answer(s, nil, { kind = "track", ws = "ux-batch", mount = "first" }, "ux-topic")
	Shim.settle()
	local branch = sh("git", { "branch", "--show-current" }, base .. "/first")
	check("track checks out the requested branch", string.match(branch, "^ux%-topic%s*$") ~= nil, s.failure and serde.encode("json", s.failure.error))
	Store.answer(s, nil, { kind = "tag", ws = "ux-batch", mount = "first" }, "ux-v1")
	Shim.settle()
	local pinned = sh("git", { "describe", "--exact-match", "--tags", "HEAD" }, base .. "/first")
	check("tag checks out the requested tag", string.match(pinned, "^ux%-v1%s*$") ~= nil, s.failure and serde.encode("json", s.failure.error))
	fs.writeFile(middle_source .. "/README.md", "new source commit\n")
	sh("git", { "add", "README.md" }, middle_source)
	sh("git", { "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "advance source" }, middle_source)
	Store.check(s, nil, "ux-batch", { refresh = true })
	Shim.settle()
	local middle_status
	for _, m in s.status["ux-batch"].data.mounts do
		if m.path == "middle" then middle_status = m end
	end
	check("remote check observes a newer source commit", middle_status and tonumber(middle_status.observed.behindCount) == 1)
	-- Make the second mount unsafe. The first is removable; the third must never be attempted.
	fs.writeFile(base .. "/middle/README.md", "uncommitted batch edit\n")
	Store.refresh(s, nil, true)
	Shim.settle()
	Shim.load(PLUGIN .. "/lenses.luau")
	local lens = Shim.lenses.dev
	local parsed = lens.open({ typed = "dev ws status ux-batch --offline", line = "dev ws status ux-batch --offline", args = { "ws", "status", "ux-batch", "--offline" } }, {})
	local human = sh(DEV, { "ws", "status", "ux-batch", "--offline", "--root", ROOT_A })
	for line in string.gmatch(human .. "\n", "(.-)\r?\n") do
		lens.line(parsed, { text = line, links = {} })
	end
	lens.finish(parsed, 0)
	local node = lens.view(parsed)
	check("status lens retains real dirty state", node ~= nil and has(table.concat(texts(node), "\n"), "dirty"), human)
	Store.dispatch(s, nil, "remove.all", "ux-batch")
	check("batch confirmation exists before any folder disappears", s.confirm ~= nil and fs.isDir(base .. "/first"))
	Store.dispatch(s, nil, "confirm.no")
	check("batch cancel keeps every mount", fs.isDir(base .. "/first") and fs.isDir(base .. "/middle") and fs.isDir(base .. "/last"))
	Store.dispatch(s, nil, "remove.all", "ux-batch")
	Store.dispatch(s, nil, "confirm.yes")
	Shim.settle()
	check("batch stops at unsafe mount", s.failure and s.failure.error.code == "UNSAFE_REMOVE", s.failure and serde.encode("json", s.failure.error))
	check("batch keeps unsafe and unattempted work", not fs.isDir(base .. "/first") and fs.readFile(base .. "/middle/README.md") == "uncommitted batch edit\n" and fs.isDir(base .. "/last"))
	sh("git", { "checkout", "--", "README.md" }, base .. "/middle")
	Store.dispatch(s, nil, "remove.all", "ux-batch")
	Store.dispatch(s, nil, "confirm.yes")
	Shim.settle()
	check("clean batch leaves workspace with no mounts", s.failure == nil and tonumber(Store.workspace(s, "ux-batch").mountCount) == 0)
end

section("mirrors: sync one, sync all, and a mirror dev lost track of")
do
	Store.answer(s, nil, { kind = "mirror" }, SRC)
	Shim.settle()
	Store.refresh(s, nil, true)
	Shim.settle()
	local m = s.mirrors[1]
	check("mirror listed and linked", m and m.linked == true, serde.encode("json", s.mirrors))
	click(s, "mirrors")
	local _, main = screen_text(s)
	check("a linked mirror has its sync button", m and actions(main)["mirror.sync=" .. m.name])
	local before = #Shim.runs
	click(s, "mirror.sync=" .. m.name)
	Shim.settle()
	local argv = table.concat(Shim.runs[before + 1] or {}, " ")
	check("syncs that mirror by its source", has(argv, "mirror sync " .. tostring(m.sourceUrl)), argv)
	check("sync one succeeds", s.failure == nil and s.notice and s.notice.tone == "success", serde.encode("json", { notice = s.notice, failure = s.failure and s.failure.error }))

	-- Remove its admin repository, as had happened in a real root.
	local gitfile = fs.readFile(m.path .. "/.git")
	local admin = string.match(gitfile, "gitdir:%s*(.-)[/\\]worktrees[/\\]")
	fs.removeDir(admin)
	Store.refresh(s, nil, true)
	Shim.settle()
	m = s.mirrors[1]
	check("dev still lists it; marked unlinked", m and m.linked == false, serde.encode("json", s.mirrors))
	local t2, main2 = screen_text(s)
	check("unlinked row says so and has no sync button", has(t2, "unlinked") and not actions(main2)["mirror.sync=" .. m.name], t2)
	before = #Shim.runs
	click(s, "mirror.sync=" .. m.name)
	Shim.settle()
	check("one unlinked mirror never turns into sync all", #Shim.runs == before, table.concat(Shim.runs[#Shim.runs] or {}, " "))
	check("explains why it cannot sync", s.failure and s.failure.error.code == "MIRROR_ADMIN_MISSING")
	click(s, "dismiss")
	click(s, "mirror.sync=")
	Shim.settle()
	check("sync all reports the skipped mirror, not done", s.failure == nil and s.notice and s.notice.tone == "warning" and has(s.notice.text, "1 skipped"), s.notice and serde.encode("json", s.notice) or (s.failure and serde.encode("json", s.failure.error)))
	click(s, "dismiss")

	click(s, "prs")
	Shim.settle()
	local pt = screen_text(s)
	check("pull requests screen answers (list or refusal)", s.prs ~= nil or s.failure ~= nil, pt)
	print("       " .. (if s.failure then "refused: " .. s.failure.error.code else "ok, " .. #s.prs .. " cached"))
	click(s, "dismiss")
	click(s, "home")
end

section("multiple roots")
do
	click(s, "roots")
	local t, main = screen_text(s)
	check("roots screen lists both", has(t, "alpha") and has(t, "beta"), t)
	check("default root marked", has(t, "default"))
	local pick_b = nil
	for a in actions(main) do
		if string.match(a, "^root=") and Store.norm(string.sub(a, 6)) == Store.norm(ROOT_B) then
			pick_b = a
		end
	end
	check("beta is clickable", pick_b ~= nil)
	click(s, pick_b or ("root=" .. ROOT_B))
	check("choice stored for both halves", Shim.kv.root ~= nil and Store.norm(Shim.kv.root) == Store.norm(ROOT_B), Shim.kv.root)
	Shim.settle()
	check("active root is beta", Store.norm(s.active_root) == Store.norm(ROOT_B), s.active_root)
	check("lists beta's workspace", names(s)["beta-only"])
	check("hides alpha's workspaces", not names(s)["alpha-seed"])
	local ht = screen_text(s)
	check("header names beta", has(ht, "beta"), ht)

	-- The other half picks the choice up on its next refresh.
	local side = new_store("sidebar")
	Store.refresh(side, nil)
	Shim.settle()
	check("other surface follows the chosen root", names(side)["beta-only"] and not names(side)["alpha-seed"])

	-- A command runs against the chosen root.
	create_reviewed({ source = "empty", name = "in-beta", desc = "" })
	Shim.settle()
	check("create lands in beta", s.failure == nil and names(s)["in-beta"], s.failure and serde.encode("json", s.failure.error))
	local in_alpha = dev({ "ls", "--root", ROOT_A })
	local leaked = false
	for _, w in in_alpha do
		leaked = leaked or w.name == "in-beta"
	end
	check("alpha untouched", not leaked)

	-- Back to the default forgets the choice.
	click(s, "root=" .. ROOT_A)
	check("default choice clears the stored root", Shim.kv.root == nil, Shim.kv.root)
	Shim.settle()
	check("back on alpha", names(s)["alpha-seed"] and not names(s)["beta-only"])

	-- A stored root that is no longer registered falls back to the default instead of an empty list.
	Shim.kv.root = TMP .. "/gone-root"
	click(s, "refresh")
	Shim.settle()
	check("unregistered root falls back to default", names(s)["alpha-seed"], s.active_root)
	check("fallback explained", s.notice and has(s.notice.text, "no longer registered"), s.notice and s.notice.text)
	check("stale choice cleared", Shim.kv.root == nil)
end

section("dev missing or broken")
do
	Shim.env_override.DEV_TERN_BIN = TMP .. "/nope/dev.exe"
	local b = new_store()
	Store.refresh(b, nil)
	Shim.settle()
	check("missing binary is a SPAWN error, not a hang", b.loading == false and b.load_error and b.load_error.code == "SPAWN", b.load_error and serde.encode("json", b.load_error))
	local t, main = screen_text(b)
	check("problem card with Reload", has(t, "dev is not answering") and actions(main)["refresh"], t)
	Shim.env_override.DEV_TERN_BIN = DEV
	click(b, "refresh")
	Shim.settle()
	check("reload after fixing works", b.load_error == nil and names(b)["alpha-seed"], b.load_error and serde.encode("json", b.load_error))

	-- dev printing garbage
	local fake = TMP .. (if process.os == "windows" then "/fake-dev.cmd" else "/fake-dev")
	fs.writeFile(fake, if process.os == "windows" then "@echo off\r\necho not json\r\n" else "#!/bin/sh\nprintf 'not json\\n'\n")
	if process.os ~= "windows" then sh("/bin/chmod", { "+x", fake }) end
	Shim.env_override.DEV_TERN_BIN = fake
	local g = new_store()
	Store.refresh(g, nil)
	Shim.settle()
	check("garbage output is a visible error", g.loading == false and g.load_error ~= nil, g.load_error and g.load_error.code)
	if g.load_error then
		print("       code: " .. g.load_error.code)
	end
	Shim.env_override.DEV_TERN_BIN = DEV
end

section("window half: sidebar, commands, route")
do
	local cx = Shim.window_cx()
	Shim.cx = cx
	Shim.load(PLUGIN .. "/host.luau")
	Shim.load(PLUGIN .. "/window.luau")
	Shim.commands.goto.run(cx)
	Shim.settle()
	local initial_pick = cx.record.picks[1]
	local listed_seed = false
	for _, item in (initial_pick and initial_pick.items) or {} do
		listed_seed = listed_seed or item.label == "alpha-seed"
	end
	check("cold picker loads registered workspace choices", listed_seed)
	local file_button = Shim.files_buttons["devcli-add"]
	cx.pick_answers = { { label = "alpha-seed", ws_path = Store.workspace(s, "alpha-seed").path, root = s.active_root } }
	local picks_before, runs_before = #cx.record.picks, #Shim.runs
	file_button.run({ host = "", root = SRC, selection = {}, tab = "files" }, cx)
	Shim.settle()
	local confirm = cx.record.picks[picks_before + 2]
	check("Files add previews a relative mount destination", confirm and has(confirm.items[1].detail, "--path lib"), confirm and confirm.items[1].detail)
	local added = false
	for i = runs_before + 1, #Shim.runs do
		local argv = Shim.runs[i]
		added = added or (argv[2] == "ws" and argv[3] == "add")
	end
	check("dismissing Files confirmation never mounts the repository", not added and not fs.isDir(string.gsub(Store.workspace(s, "alpha-seed").path, "\\", "/") .. "/lib"))
	check("commands registered", Shim.commands.sidebar and Shim.commands.panel and Shim.commands.refresh)
	Shim.commands.sidebar.run(cx)
	Shim.settle()
	local pane, entry = next(cx.native_panes)
	check("sidebar is an editable native navigator", entry ~= nil and has_kind(entry.view.main, "input"))
	local t = entry and table.concat(texts(entry.view.main), "\n") or ""
	check("sidebar lists workspaces", has(t, "alpha-seed"), t)
	check("sidebar no duplicate keys", entry and #duplicate_keys(entry.view.main) == 0)
	local before = #Shim.runs
	cx.session:event(pane, { ev = "action", act = "refresh" })
	Shim.settle()
	check("sidebar refresh reloads the workspace inventory", #Shim.runs > before and names(entry.state.store)["alpha-seed"])
	cx.session:event(pane, { ev = "action", act = "open", value = "alpha-seed" })
	local destination = cx.record.picks[#cx.record.picks]
	check("open asks for a session without creating one on cancellation", destination and has(destination.placeholder, "alpha-seed") and #cx.record.sessions == 0)
	-- Route from the block.
	local r = Shim.route({ url = "devcli://copy?text=dev%20ls" }, cx)
	check("route handles copy", r and r.handled and cx.record.copies[1] == "dev ls", cx.record.copies[1])
	local r2 = Shim.route({ url = "devcli://edit?path=C%3A%2Fx%2Fws.md" }, cx)
	check("route opens ws.md in Tern's editor", r2 and r2.handled and cx.record.docs[1] and cx.record.docs[1].path == "C:/x/ws.md", cx.record.docs[1] and cx.record.docs[1].path)
	-- Description: a prompt in the window, then ws.md through the live document, even while it is open with
	-- unsaved edits.
	local function act_sidebar(name: string, value: string)
		cx.session:event(pane, { ev = "action", act = name, value = value })
		Shim.settle()
	end
	act_sidebar("manifest", "alpha-seed")
	local md = cx.record.docs[#cx.record.docs].path
	check("Edit ws.md opens this workspace's ws.md", has(md, "alpha-seed") and has(md, "ws.md"), md)
	local buf = cx.docs.buffers[md]
	buf.text ..= "\nunsaved note from the editor\n"
	buf.dirty = true
	cx.prompt_answer = 'descrição "pela" janela'
	act_sidebar("describe", "alpha-seed")
	local asked = cx.record.prompts[#cx.record.prompts]
	check("prompt starts with the current description", asked and asked.value == "seed workspace", asked and asked.value)
	local listed = {}
	for _, w in dev({ "ls", "--root", ROOT_A }) do
		listed[w.name] = w.description
	end
	check("saved: dev reads the new description", listed["alpha-seed"] == 'descrição "pela" janela', listed["alpha-seed"])
	local disk = fs.readFile(md)
	check("the open buffer's unsaved edits are kept", has(disk, "unsaved note from the editor") and has(buf.text, "pela") and not buf.dirty, disk)
	check("dev status still reads ws.md", dev({ "ws", "status", "alpha-seed", "--root", ROOT_A, "--offline" }) ~= nil)
	check("change stamped for panel blocks", Shim.kv.changed ~= nil)
	check("success toast", cx.record.toasts[#cx.record.toasts].level == "success", serde.encode("json", cx.record.toasts[#cx.record.toasts]))

	cx.prompt_answer = nil
	act_sidebar("describe", "alpha-seed")
	check("dismissed prompt writes nothing", fs.readFile(md) == disk)

	local good = buf.text
	buf.text, buf.dirty = "# no frontmatter\n", true
	cx.prompt_answer = "anything"
	act_sidebar("describe", "alpha-seed")
	local last = cx.record.toasts[#cx.record.toasts]
	check("broken ws.md: error toast, file untouched", last.level == "error" and has(last.text, "Description not changed") and fs.readFile(md) == disk, serde.encode("json", last))
	buf.text, buf.dirty = good, false
	Shim.commands.sidebar.run(cx)
	check("toggle parks the sidebar without destroying context", entry.info.parked == true and cx.native_panes[pane] == entry)
end

section("host block: create and add forms")
do
	Shim.load(PLUGIN .. "/host.luau")
	local def = Shim.blocks.panel
	check("panel block defined", def ~= nil)
	local opened = {}
	local bcx = {
		pane = 900,
		renders = 0,
		render = function(self)
			self.renders += 1
		end,
		frame = function() end,
		open = function(_, url)
			table.insert(opened, url)
		end,
		copy = function() end,
		toast = function() end,
	}
	Shim.panes = { { pane = 900 } }
	local state = def.init(bcx, { "create" }, nil)
	Shim.settle()
	check("block loaded workspaces", names(state.store)["alpha-seed"], state.store.load_error and serde.encode("json", state.store.load_error))
	local view = def.view(state, bcx)
	check("create dialog renders above the inventory", view.layer ~= nil and has_kind(view.layer, "input") and names(state.store)["alpha-seed"])
	check("dialog no duplicate keys", #duplicate_keys(view.layer) == 0, table.concat(duplicate_keys(view.layer), ", "))
	local function type_into(key: string, text: string)
		local f = state.fields[key]
		def.event(state, { ev = "edit", id = "layer.dialog.form." .. key, from = 0, to = 0, len = 0, text = text }, bcx)
		return f
	end
	local renders_before = bcx.renders
	type_into("f_name", "alpha-seed")
	check("an edit draws the form again", bcx.renders > renders_before, tostring(bcx.renders))
	local taken = def.view(state, bcx).layer
	check("typing an existing name warns and offers to open it", has(table.concat(texts(taken), "\n"), "A workspace named alpha-seed already exists") and actions(taken)["ws=alpha-seed"] ~= nil, table.concat(texts(taken), "\n"))
	def.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 0, to = #"alpha-seed", len = #"alpha-seed", text = "typed-in-block" }, bcx)
	check("editing replaces the candidate workspace name", state.fields.f_name.text == "typed-in-block", state.fields.f_name.text)
	type_into("f_desc", "from the form")
	def.key(state, { name = "enter" }, bcx)
	Shim.settle()
	check("enter resolves a review without creating files", state.store.creation ~= nil and not names(state.store)["typed-in-block"])
	def.key(state, { name = "enter" }, bcx)
	Shim.settle()
	check("enter creates the workspace", names(state.store)["typed-in-block"], state.store.failure and serde.encode("json", state.store.failure.error))
	check("block shows the new workspace", state.store.selected == "typed-in-block")

	def.event(state, { ev = "action", act = "add", value = "typed-in-block" }, bcx)
	check("add opens a dialog over the selected workspace", state.store.modal == "add" and state.store.selected == "typed-in-block")
	type_into("f_repo", SRC)
	def.event(state, { ev = "action", act = "readonly" }, bcx)
	def.event(state, { ev = "action", act = "submit" }, bcx)
	Shim.settle()
	local w = Store.workspace(state.store, "typed-in-block")
	check("add from the block mounts the repo", state.store.failure == nil and w and tonumber(w.mountCount) == 1, state.store.failure and serde.encode("json", state.store.failure.error))
	def.key(state, { name = "escape" }, bcx)
	check("escape leaves the completed dialog closed", state.store.modal == nil)

	def.event(state, { ev = "action", act = "create" }, bcx)
	check("create description uses a wrapping editor in the dialog", has_kind(def.view(state, bcx).layer, "editor"))
	type_into("f_desc", "linha um\r\nlinha dois")
	check("a line break typed in the description becomes a space", state.fields.f_desc.text == "linha um linha dois", state.fields.f_desc.text)
	def.key(state, { name = "escape" }, bcx)

	def.event(state, { ev = "action", act = "ws", value = "typed-in-block" }, bcx)
	def.event(state, { ev = "action", act = "describe", value = "typed-in-block" }, bcx)
	local link = opened[#opened]
	check("block hands the description edit to the window", has(link, "devcli://describe?") and has(link, "ws=typed-in-block"), link)
end

section("settings overlay and native placement")
do
	local cx = Shim.window_cx()
	Shim.cx = cx
	Shim.kv.sidebar, Shim.kv.surface = false, nil
	Shim.commands.sidebar.run(cx)
	Shim.settle()
	local pane, entry = next(cx.native_panes)
	local count = #cx.record.blocks
	Shim.commands.settings.run(cx)
	Shim.settle()
	check("Settings overlays the existing navigator without another pane", #cx.record.blocks == count and has_kind(entry.view.layer, "overlay"))
	entry.def.event(entry.state, { ev = "action", act = "surface", value = "panel" }, entry.cx)
	check("panel preference preserves the same navigator", Shim.kv.surface == "panel" and #cx.record.blocks == count and cx.native_panes[pane] == entry)
	entry.def.key(entry.state, { name = "escape" }, entry.cx)
	entry.cx:render()
	check("Escape dismisses settings without destroying the inspected screen", not has_kind(entry.view.layer, "overlay") and entry.info.parked ~= true)
	entry.info.title = "A title is not a block identifier"
	Shim.commands.open.run(cx)
	check("Open reuses the registered native block regardless of title", #cx.record.blocks == count)
	Shim.route({ url = "devcli://surface?value=sidebar" }, cx)
	Shim.commands.open.run(cx)
	check("Hide parks the chosen native sidebar", entry.info.parked == true)
	Shim.commands.open.run(cx)
	check("Show reuses its parked state", entry.info.parked == false and #cx.record.blocks == count)
end

-- Report -----------------------------------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, #failures))
for _, f in failures do
	print("  - " .. f)
end
if #Shim.logs > 0 then
	print("\nplugin log:")
	for _, l in Shim.logs do
		print("  " .. l)
	end
end
if #failures == 0 then
	pcall(fs.removeDir, TMP)
end
process.exit(if #failures == 0 then 0 else 1)
