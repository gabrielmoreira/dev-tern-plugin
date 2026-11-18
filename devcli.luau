--!nonstrict
-- The dev port, implemented by running the dev CLI (`--json --non-interactive`). The store calls operations by
-- name with a plain input table and gets `{ ok, value, warning? }` or `{ ok = false, error }` back; argv, timeouts and
-- output parsing stay in here, so a future dev API can replace this file without touching the store or view.
--
-- Every operation: `DevCli.<op>(input, done)`, `done(result, cx)`; `cx` is a fresh window cx in the window
-- half and nil in the host (and on a spawn failure, which answers synchronously).
-- Inputs name the root: `input.root` (nil lets dev pick its default).

local ShellEnv = require("./shellenv")
local Redaction = require("./redaction")

local DevCli = {}

local READ_MS = 60 * 1000
local SLOW_MS = 15 * 60 * 1000

export type DevError = {
	code: string,
	message: string,
	nextStep: string?, -- display text from dev, never run
	details: { [string]: any },
	detail: string?, -- raw output, when dev gave no error envelope
}

export type Result = { ok: boolean, value: any, error: DevError?, warning: DevError? }

-- Locating dev ------------------------------------------------------------------------------------------------

local function exists(path: string): boolean
	local ok, found = pcall(tern.fs.exists, path)
	return ok and found == true
end

-- "5.4.1" -> { 5, 4, 1 }; nil for "latest" and other non-version folders.
local function version_of(name: string): { number }?
	if not string.match(name, "^v?%d+[%.%d]*$") then
		return nil
	end
	local parts = {}
	for n in string.gmatch(name, "%d+") do
		table.insert(parts, tonumber(n) :: number)
	end
	return parts
end

local function newer(a: { number }, b: { number }): boolean
	for i = 1, math.max(#a, #b) do
		local x, y = a[i] or 0, b[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

-- The newest `<installs>/github-gabrielmoreira-dev-cli/<version>/<exe>` that exists.
local function newest_install(installs: string, exe: string): string?
	local dir = installs .. "/github-gabrielmoreira-dev-cli"
	if not exists(dir) then
		return nil
	end
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return nil
	end
	local best, best_version = nil, nil
	for _, name in names do
		local v = version_of(name)
		local candidate = dir .. "/" .. name .. "/" .. exe
		if v and exists(candidate) and (best_version == nil or newer(v, best_version)) then
			best, best_version = candidate, v
		end
	end
	return best
end

local located: string? = nil

-- Resolve PATH in the same cwd/environment that will run dev, including project-selected tool versions.
local function on_path(name: string, env, cwd: string?): string?
	local windows = tern.runtime.os == "windows"
	for entry in string.gmatch(ShellEnv.path(env), if windows then "[^;]+" else "[^:]+") do
		local dir = string.match(entry, '^"(.*)"$') or entry
		if cwd and not string.match(dir, "^[/\\]") and not string.match(dir, "^%a:[/\\]") then dir = cwd .. "/" .. dir end
		local candidate = dir .. "/" .. name
		if exists(candidate) then return candidate end
	end
	return nil
end

local function mise_installs(windows: boolean): { string }
	local roots: { string } = {}
	local function add(path: string?)
		if path and path ~= "" then
			table.insert(roots, (string.gsub(path, "\\", "/")))
		end
	end
	add(tern.getenv("MISE_INSTALLS_DIR"))
	local data = tern.getenv("MISE_DATA_DIR")
	if data then add(data .. "/installs") end
	if windows then
		local local_app = tern.getenv("LOCALAPPDATA")
		if local_app then add(local_app .. "/mise/installs") end
	else
		local home = tern.getenv("HOME")
		if home then add(home .. "/.local/share/mise/installs") end
	end
	return roots
end

local function mise_shim(roots: { string }, exe: string): string?
	for _, installs in roots do
		local data_root = string.match(installs, "^(.*)/installs/?$")
		local shim = data_root and (data_root .. "/shims/" .. exe)
		if shim and exists(shim) then return shim end
	end
	return nil
end

-- Explicit and PATH selection first; desktop launches without dev use the configured mise shim.
function DevCli.binary(env: { [string]: string }?, cwd: string?): string
	local override = (env and env.DEV_TERN_BIN) or tern.getenv("DEV_TERN_BIN")
	if override and override ~= "" then return override end
	local windows = tern.runtime.os == "windows"
	local exe = if windows then "dev.exe" else "dev"
	local from_path = on_path(exe, env, cwd)
	if from_path then return from_path end
	-- An explicitly initialized shell is authoritative, including a missing tool.
	if env and ShellEnv.config().mode == "shell" then return "dev" end
	local roots = mise_installs(windows)
	-- A shim follows mise's configured version, including linked prereleases, before a cached fallback.
	local shim = mise_shim(roots, exe)
	if shim then return shim end
	if located then return located end
	for _, installs in roots do
		local found = newest_install(installs, exe)
		if found then
			located = found
			return found
		end
	end
	located = "dev"
	return "dev"
end

-- Reading answers ---------------------------------------------------------------------------------------------

local function first_lines(text: string, n: number): string
	local out = {}
	for line in string.gmatch(text, "[^\r\n]+") do
		table.insert(out, line)
		if #out == n then
			break
		end
	end
	return table.concat(out, "\n")
end

local ENVELOPE_KEYS = { code = true, message = true, nextStep = true, details = true }

-- The `{"error": {...}}` envelope dev prints, or nil. dev puts context either under `details` or beside
-- `code` (`name`, `path`, …); both land in `details`.
local function envelope(text: string): DevError?
	local start = string.find(text, "{", 1, true)
	if not start then
		return nil
	end
	local stop = start
	for i = #text, start, -1 do
		if string.sub(text, i, i) == "}" then
			stop = i
			break
		end
	end
	local ok, decoded = pcall(tern.json.decode, string.sub(text, start, stop))
	if not ok or type(decoded) ~= "table" or type(decoded.error) ~= "table" then
		return nil
	end
	local e = decoded.error
	local details = {}
	if type(e.details) == "table" then
		for k, v in e.details do
			details[k] = v
		end
	end
	for k, v in e do
		if not ENVELOPE_KEYS[k] and details[k] == nil then
			details[k] = v
		end
	end
	return {
		code = if type(e.code) == "string" then e.code else "ERROR",
		message = if type(e.message) == "string" then e.message else "dev reported an error.",
		nextStep = if type(e.nextStep) == "string" and e.nextStep ~= "" then e.nextStep else nil,
		details = details,
	}
end

local function failure(code: string, message: string, detail: string?): Result
	return { ok = false, error = { code = code, message = message, detail = detail, details = {} } }
end

-- A finished process as `{ ok, value = decoded JSON }` or `{ ok = false, error }`.
function DevCli.decode(result: ProcessResult): Result
	if result.timed_out then
		return failure("TIMEOUT", "dev did not finish in time; it was stopped.")
	end
	if result.status == 0 then
		if string.match(result.stdout, "^%s*$") then
			return { ok = true, value = nil }
		end
		local ok, data = pcall(tern.json.decode, result.stdout)
		if ok then
			return { ok = true, value = data }
		end
		return failure("BAD_OUTPUT", "dev printed something other than JSON.", first_lines(result.stdout, 6))
	end
	local found = envelope(result.stderr) or envelope(result.stdout)
	if found then
		return { ok = false, error = found }
	end
	return failure(
		"FAILED",
		"dev exited with status " .. tostring(result.status) .. ".",
		first_lines(result.stderr .. "\n" .. result.stdout, 8)
	)
end

-- Decoded arrays carry Tern's protected array tag (table.clone and friends refuse them); copy into a plain
-- table the store may sort.
local function list(value: any): { any }
	local out = {}
	if type(value) == "table" then
		for _, item in value do
			table.insert(out, item)
		end
	end
	return out
end

-- Operations --------------------------------------------------------------------------------------------------

local function flag(argv: { string }, on: any, name: string)
	if on then
		table.insert(argv, name)
	end
end

local function option(argv: { string }, value: any, name: string)
	if type(value) == "string" and value ~= "" then
		table.insert(argv, name)
		table.insert(argv, value)
	end
end

type Op = {
	argv: (i: { [string]: any }) -> { string },
	tail: ((i: { [string]: any }) -> { string })?, -- after `--`, past dev's own flags (qmd options)
	slow: boolean?, -- network or worktree work: the long timeout
	unrooted: boolean?, -- reads ~/.dev.toml, takes no --root
	read: ((data: any, i: { [string]: any }) -> any)?, -- dev's JSON to the value the store gets; nil = bad shape
}

-- dev's business reasons for leaving a mirror alone, in words.
local SKIP_TEXT = {
	DIRTY_WORKTREE = "has local edits",
	DIVERGED = "diverged from its remote",
	AHEAD_COMMITS = "has local commits not on the remote",
}

-- The CLI's ADO cache records identify the provider by tenant, not a `provider` field.
local function discard_copied_pr_update(record)
	local tenant, url = string.lower(tostring(record.tenant or "")), string.lower(tostring(record.url or ""))
	local ado = record.provider == "ado" or string.match(tenant, "^dev%.azure%.com/")
		or string.match(tenant, "^https?://dev%.azure%.com/") or string.match(tenant, "^https?://[^/]+%.visualstudio%.com")
		or string.match(url, "^https?://dev%.azure%.com/") or string.match(url, "^https?://[^/]+%.visualstudio%.com/")
	if ado and record.updatedAt == record.createdAt then record.updatedAt = nil end
end

local OPS: { [string]: Op } = {
	-- Registered roots: { alias, path, isDefault, isActive }.
	roots = { unrooted = true, argv = function()
		return { "roots" }
	end, read = list },

	-- The root dev would use: { root, source }. `i.root` asks about that root instead.
	current = {
		unrooted = true,
		argv = function(i)
			local argv = { "current" }
			option(argv, i.root, "--root")
			return argv
		end,
		read = function(data)
			if type(data) ~= "table" or type(data.root) ~= "string" then
				return nil
			end
			return { root = data.root, source = data.source }
		end,
	},

	-- Workspaces: { name, path, description, createdAt, lastUsedAt, mountCount }.
	workspaces = { argv = function()
		return { "ls" }
	end, read = list },

	-- Mirrors: { name, branch, path, sourceUrl?, isClean, ahead, behind, linked }. dev still lists a checkout
	-- whose admin repository under .dev/repos vanished (no source, branch "unknown"), but cannot sync it:
	-- `linked = false` marks those.
	mirrors = {
		argv = function()
			return { "mirror", "ls" }
		end,
		read = function(data)
			local out = {}
			for _, m in list(data) do
				table.insert(out, {
					name = m.name,
					branch = m.branch,
					path = m.path,
					sourceUrl = m.sourceUrl,
					isClean = m.isClean,
					ahead = m.ahead,
					behind = m.behind,
					linked = not (m.sourceUrl == nil and m.branch == "unknown"),
				})
			end
			return out
		end,
	},

	-- Mount states of `i.ws`: from disk, or with `i.refresh` after fetching the remotes.
	status = {
		argv = function(i)
			return { "ws", "status", i.ws, if i.refresh then "--refresh" else "--offline" }
		end,
	},

	worksets = { argv = function()
		return { "workset", "list" }
	end, read = list },

	workset = {
		argv = function(i)
			return { "workset", "show", i.name }
		end,
		read = function(data, i)
			if type(data) ~= "table" then return nil end
			local out = {}
			for key, value in data do out[key] = value end
			out.name = i.name
			return out
		end,
	},

	save_workset = {
		slow = true,
		argv = function(i)
			local argv = { "workset", "save", i.name, "--definition-json", tern.json.encode(i.definition) }
			option(argv, i.original_name, "--original")
			return argv
		end,
		read = function(data, i)
			local out = {}
			if type(data) == "table" then
				for key, value in data do out[key] = value end
			else
				for key, value in i.definition do out[key] = value end
			end
			out.name = if type(data) == "table" and type(data.name) == "string" then data.name else i.name
			return out
		end,
	},

	labels = { argv = function()
		return { "label", "list" }
	end, read = list },

	catalog = {
		argv = function()
			return { "sync", "inventory", "--offline" }
		end,
		read = function(data)
			local rows = if type(data) == "table" and type(data.repositories) == "table" then data.repositories else list(data)
			local out = {}
			for _, record in rows do
				if type(record) == "table" and record.disabled ~= true and type(record.url) == "string" and record.url ~= "" then
					table.insert(out, {
						name = record.name,
						url = record.url,
						default_branch = record.default_branch or record.defaultBranch,
						description = record.description,
						project = record.project,
						organization = record.organization,
					})
				end
			end
			return out
		end,
	},

	create_plan = {
		slow = true,
		argv = function(i)
			local form = i.form or i
			local argv = { "ws", "init" }
			local proposal = if form.source == "url" then form.url else form.name
			if type(proposal) == "string" and proposal ~= "" then table.insert(argv, proposal) end
			flag(argv, true, "--dry-run")
			local mounts = if form.source == "repositories" then (form.mounts or form.repositories or {}) else form.mounts
			if type(mounts) == "table" then option(argv, if #mounts == 0 then "[]" else tern.json.encode(mounts), "--mounts-json") end
			if form.source == "url" then option(argv, form.name, "--name") end
			option(argv, form.desc, "--desc")
			option(argv, form.setup, "--setup")
			if form.source == "workset" then option(argv, form.workset, "--workset") end
			if form.source == "label" and type(form.labels) == "table" and #form.labels > 0 then
				local labels = {}
				for _, label in form.labels do table.insert(labels, tostring(label)) end
				option(argv, table.concat(labels, ","), "--label")
			end
			return argv
		end,
		read = function(data)
			if type(data) ~= "table" or type(data.name) ~= "string" or type(data.path) ~= "string" or type(data.mounts) ~= "table" then
				return nil
			end
			return data
		end,
	},

	-- Pull requests; query scope/filters are passed through to the CLI's cache-aware list contract.
	pull_requests = {
		slow = true,
		argv = function(i)
			local argv = { "pr", "list" } -- no --limit: dev's own default returns the whole collection
			flag(argv, not i.live, "--offline")
			flag(argv, i.scope == "all", "--all")
			flag(argv, i.scope ~= "all", "--mine")
			option(argv, i.status, "--status")
			option(argv, i.repo, "--repo")
			option(argv, i.provider, "--provider")
			option(argv, i.project, "--project")
			option(argv, i.ws, "--ws")
			option(argv, i.label, "--label")
			return argv
		end,
		read = function(value)
			if type(value) ~= "table" then return nil end
			if value.items == nil then
				local items = list(value)
				for _, item in items do
					discard_copied_pr_update(item)
				end
				return items
			end
			if type(value.items) ~= "table" or type(value.errors) ~= "table" then return nil end
			local warning
			if #value.errors > 0 then
				warning = {
					code = "PARTIAL_READ",
					message = "Some providers did not return pull requests.",
					detail = Redaction.text(table.concat(list(value.errors), "\n")),
					details = {},
					nextStep = "Run dev doctor to review provider access, then fetch again.",
				}
			end
			local items = list(value.items)
			for _, item in items do
				discard_copied_pr_update(item)
			end
			return items, warning
		end,
	},

	-- Executes a reviewed `{name, desc?, mounts}` plan with `--yes`; no draft source or recipe is resolved here.
	-- The store passes only the exact mounts returned by create_plan.
	create = {
		slow = true,
		argv = function(i)
			local argv = { "ws", "init", i.name or "" }
			option(argv, i.desc, "--desc")
			if type(i.repositories) == "table" then option(argv, if #i.repositories == 0 then "[]" else tern.json.encode(i.repositories), "--mounts-json") end
			flag(argv, true, "--yes")
			return argv
		end,
		read = function(data, i)
			local d = if type(data) == "table" then data else {}
			return { name = if type(d.name) == "string" then d.name else i.name, created = d.created ~= false }
		end,
	},

	-- Runs the setup each mount of `i.ws` declares; `i.consent` allows untrusted ones.
	setup = {
		slow = true,
		argv = function(i)
			local argv = { "ws", "setup", i.ws }
			flag(argv, i.consent, "--consent")
			return argv
		end,
	},

	-- Mounts `i.repo` (URL, path or known name) in `i.ws`; optional `i.branch`, `i.readonly`, `i.consent`.
	add = {
		slow = true,
		argv = function(i)
			local argv = { "ws", "add", i.repo or "", "--ws", i.ws }
			option(argv, i.branch, "--branch")
			option(argv, i.path, "--path")
			flag(argv, i.readonly, "--readonly")
			flag(argv, i.consent, "--consent")
			return argv
		end,
	},

	-- Converges `i.ws`; `i.dry_run` only plans. `i.autostash` / `i.rebase` / `i.consent` as dev documents them.
	-- A plan answers dev's plan; an update answers { summary = { updated, upToDate, skipped } }.
	update = {
		slow = true,
		argv = function(i)
			local argv = { "ws", "update", i.ws }
			flag(argv, i.dry_run, "--dry-run")
			flag(argv, i.autostash, "--autostash")
			flag(argv, i.rebase, "--rebase")
			flag(argv, i.consent, "--consent")
			return argv
		end,
	},

	lock = { argv = function(i)
		return { "ws", "lock", i.mount, "--ws", i.ws }
	end },

	unlock = { slow = true, argv = function(i)
		return { "ws", "unlock", i.mount, "--ws", i.ws }
	end },

	-- Tracks branch `i.branch` in mount `i.mount` of `i.ws` (checks it out).
	track = { slow = true, argv = function(i)
		return { "ws", "track", i.mount, i.branch, "--ws", i.ws }
	end },

	-- Pins mount `i.mount` of `i.ws` to tag `i.tag`.
	tag = { slow = true, argv = function(i)
		return { "ws", "tag", i.mount, i.tag, "--ws", i.ws }
	end },

	-- dev refuses (UNSAFE_REMOVE) when work would be lost; this never forces.
	remove = { argv = function(i)
		return { "ws", "remove", i.mount, "--ws", i.ws, "--yes" }
	end },

	-- Starts or focuses OMP in HerdR: { reused }.
	start = {
		slow = true,
		argv = function(i)
			return { "ws", "start", i.ws }
		end,
		read = function(data)
			return { reused = type(data) == "table" and data.reused == true }
		end,
	},

	-- `i.source`: one mirror by source URL (dev 5.4 resolves bare names only for linked mirrors); nil syncs all.
	-- Answers { updated, stashed, up_to_date, skipped = { { path, reason } } }. dev lists up-to-date mirrors as
	-- skipped too; `skipped` keeps only the ones that need a person (local commits, divergence, errors).
	sync_mirrors = {
		slow = true,
		argv = function(i)
			local argv = { "mirror", "sync" }
			if type(i.source) == "string" and i.source ~= "" then
				table.insert(argv, i.source)
			end
			return argv
		end,
		read = function(data)
			local d = if type(data) == "table" then data else {}
			local skipped, current = {}, 0
			for _, item in list(d.skipped) do
				if item.reason == "UP_TO_DATE" and item.code == nil then
					current += 1
				else
					local why = SKIP_TEXT[item.reason]
						or string.gsub(tostring(item.reason or item.code or "no reason given"), "^[%u_]+: ", "")
					table.insert(skipped, { path = tostring(item.path or "?"), reason = why })
				end
			end
			return { updated = #list(d.updated), stashed = #list(d.stashed), up_to_date = current, skipped = skipped }
		end,
	},

	sync_providers = { slow = true, argv = function()
		return { "sync", "data" }
	end },

	-- Creates a workspace from pull request `i.ref` (URL or id).
	checkout_pr = { slow = true, argv = function(i)
		return { "pr", "checkout", i.ref }
	end },

	-- Mirrors `i.repo` (URL, path or known name); optional `i.name`, `i.branch`.
	mirror_add = {
		slow = true,
		argv = function(i)
			local argv = { "mirror", "add", i.repo or "" }
			option(argv, i.name, "--name")
			option(argv, i.branch, "--branch")
			return argv
		end,
	},

	-- Work items: { id, type, title, state, assignedTo?, author?, url, project? }. Live reads may pin explicit
	-- provider/project choices returned by INTERACTION_REQUIRED.
	work_items = {
		slow = true,
		argv = function(i)
			local argv = { "wi", "list", "--limit", "50" }
			table.insert(argv, if i.live then "--refresh" else "--offline")
			option(argv, i.provider, "--provider")
			option(argv, i.project, "--project")
			return argv
		end,
		read = list,
	},

	-- One work item from the cache: `i.id` in the namespace `i.tenant` / `i.project` (the same ID exists elsewhere).
	-- The list fields plus description, areaPath, iterationPath.
	work_item = { argv = function(i)
		local argv = { "wi", "view", tostring(i.id), "--offline" }
		option(argv, i.tenant, "--tenant")
		option(argv, i.project, "--project")
		return argv
	end },

	-- One pull request `i.ref`, from the cache. Drop only ADO's adapter-level duplicate creation timestamp.
	pull_request = {
		argv = function(i)
			return { "pr", "view", i.ref, "--offline" }
		end,
		read = function(value)
			if type(value) ~= "table" then return nil end
			discard_copied_pr_update(value)
			return value
		end,
	},

	-- { status, root = { path, exists, hasDevDir }, tools = { { name, required, available, version } },
	-- providerList = { { id, type, target, configured, credentialSource } }, messages }.
	doctor = { argv = function()
		return { "doctor" }
	end },

	-- qmd search over the indexed mirrors: { { docid, score, file, line, title, snippet } }; `--full-path`
	-- makes `file` a path on disk.
	search = {
		argv = function(i)
			return { "qmd", "search", i.query or "" }
		end,
		tail = function()
			return { "--full-path", "-n", "20" }
		end,
		read = list,
	},
}

local function run(name: string, op: Op, input: { [string]: any }?, done: (Result, any) -> ())
	local i = input or {}
	local home = if tern.runtime.os == "windows" then tern.getenv("USERPROFILE") else tern.getenv("HOME")
	local cwd = i.cwd or (if type(i.root) == "string" and exists(i.root) then i.root else home)
	local started = tern.now()
	local config = ShellEnv.config()
	local context = {
		operation = name, root = i.root, cwd = cwd,
		environment = if config.mode == "shell" then "shell" else "inherited",
		shell = if config.mode == "shell" then config.shell else nil,
	}
	local function finish(answer, cx)
		if not answer.ok then
			context.durationMs = math.max(0, tern.now() - started)
			answer.error.context = context
			if answer.error.code == "ENOENT" and not answer.error.nextStep then
				answer.error.nextStep = if config.mode == "shell"
					then "Repair the selected shell's tool initialization, then refresh its environment in dev settings."
					else "Open dev settings to review the execution environment, or start Tern from an initialized shell where the missing tool is available."
			end
			for _, field in { "message", "nextStep", "detail" } do
				if answer.error[field] ~= nil then answer.error[field] = Redaction.text(answer.error[field]) end
			end
		end
		done(answer, cx)
	end
	ShellEnv.resolve(cwd or ".", function(env, env_error, env_cx)
		if env_error then return finish({ ok = false, error = env_error }, env_cx) end
		local argv = { DevCli.binary(env, cwd) }
		context.executable = argv[1]
		for _, a in op.argv(i) do table.insert(argv, a) end
		table.insert(argv, "--json")
		table.insert(argv, "--non-interactive")
		if not op.unrooted and type(i.root) == "string" and i.root ~= "" then
			table.insert(argv, "--root")
			table.insert(argv, i.root)
		end
		if op.tail then
			table.insert(argv, "--")
			for _, a in op.tail(i) do table.insert(argv, a) end
		end
		local child_env = table.clone(env)
		child_env.NO_COLOR, child_env.FORCE_COLOR = "1", "0"
		local options: ProcessOptions = {
			cwd = cwd, timeout_ms = if op.slow then SLOW_MS else READ_MS, env = child_env,
		}
		local ok, err = pcall(ShellEnv.run, argv, options, function(result: ProcessResult, cx: any)
			local answer = DevCli.decode(result)
			-- Doctor reports missing required tools with exit1, but its report is still a successful read.
			if name == "doctor" and result.status == 1 and not result.timed_out then
				local parsed, report = pcall(tern.json.decode, result.stdout)
				if parsed and type(report) == "table" and report.status == "error" and type(report.root) == "table" and type(report.tools) == "table" then
					answer = { ok = true, value = report }
				end
			end
			if answer.ok and op.read then
				local value, warning = op.read(answer.value, i)
				answer = if value == nil then failure("BAD_OUTPUT", "dev answered " .. name .. " in an unexpected shape.") else { ok = true, value = value, warning = warning }
			end
			finish(answer, cx)
		end)
		if not ok then
			located = nil
			finish(failure("SPAWN", "Tern could not start dev (" .. argv[1] .. ").", tostring(err)), env_cx)
		end
	end)
end

for name, op in OPS do
	DevCli[name] = function(input, done)
		run(name, op, input, done)
	end
end

-- Operations dev has no command for, done on the files dev reads. A dev API would answer these too.

local function sep(path: string): string
	return if string.find(path, "\\") then "\\" else "/"
end

-- Visible folders in workspace `path` that are no mount (`mounts`: mount paths, relative) and not `.local`.
-- Answers { { name, path, git } } sorted by name; a folder dev does not track holds work dev never sees.
function DevCli.folders(path: string, mounts: { string }): { { name: string, path: string, git: boolean } }
	local known = {}
	for _, m in mounts do
		known[string.match(m, "^[^/\\]+") or m] = true
	end
	local ok, names = pcall(tern.fs.list, path)
	local out = {}
	if not ok then
		return out
	end
	local s = sep(path)
	for _, name in names do
		local full = path .. s .. name
		if string.sub(name, 1, 1) ~= "." and not known[name] and pcall(tern.fs.list, full) then
			table.insert(out, { name = name, path = full, git = exists(full .. s .. ".git") })
		end
	end
	return out
end

-- File browsing: tern.fs can neither classify an entry without listing it nor report modification times, so
-- directory pages and ws.md come from one inline Bun script (node:fs, Bun is a dev doctor prerequisite). It is
-- started like dev is: through ShellEnv, with the arguments passed separately, never through a shell. One
-- request reads one directory: all Dirents are sorted (directories first, then name), only the requested page
-- is stat'ed, and nothing below it is read.

local MANIFEST_MAX_BYTES = 256 * 1024
local DIR_PAGE = 100

local FS_SCRIPT = [=[
const fs=require("node:fs");const [,mode,path,a,b]=process.argv;
const out=v=>process.stdout.write(JSON.stringify(v));
const sec=s=>Math.floor(s.mtimeMs/1000);
const cmp=(x,y)=>x<y?-1:x>y?1:0;
try{
if(mode==="dir"){
const all=fs.readdirSync(path,{withFileTypes:true});
all.sort((x,y)=>{const dx=x.isDirectory(),dy=y.isDirectory();return dx!==dy?(dx?-1:1):(cmp(x.name.toLowerCase(),y.name.toLowerCase())||cmp(x.name,y.name))});
const lim=Math.max(1,Math.min(500,Number(b)||100)),total=all.length;
let off=Math.max(0,Math.floor(Number(a)||0));if(off>=total)off=total>0?Math.floor((total-1)/lim)*lim:0;
const sep=path.includes("\\")?"\\":"/",base=path.replace(/[\\/]+$/,"");
const entries=all.slice(off,off+lim).map(d=>{const p=base+sep+d.name,link=d.isSymbolicLink();let st=null,ls=null;
try{st=fs.statSync(p)}catch{}try{ls=st||fs.lstatSync(p)}catch{}
const e={name:d.name,path:p,directory:d.isDirectory()||(link&&!!st&&st.isDirectory())};
if(ls)e.modifiedAt=sec(ls);if(link)e.link=true;if(link&&!st)e.broken=true;return e});
out({entries,total,offset:off});
}else{
const st=fs.statSync(path);
if(!st.isFile())throw Object.assign(new Error("not a regular file"),{code:"ENOTFILE"});
if(st.size>Number(a))throw Object.assign(new Error("larger than "+a+" bytes"),{code:"E2BIG"});
out({text:fs.readFileSync(path,"utf8"),modifiedAt:sec(st)});
}
}catch(e){out({error:{code:e.code||"ERROR",message:String(e.message)}})}
]=]

local function join(parent: string, name: string): string
	return (string.gsub(parent, "[/\\]+$", "")) .. sep(parent) .. name
end

-- Runs the script in `cwd` (when it exists) with `args`; answers its JSON object or a DevError.
local function bun(args: { string }, cwd: string, done: (Result, any) -> ())
	local windows = tern.runtime.os == "windows"
	local home = if windows then tern.getenv("USERPROFILE") else tern.getenv("HOME")
	local dir = if exists(cwd) then cwd else home
	ShellEnv.resolve(dir or ".", function(env, env_error, env_cx)
		if env_error then
			return done({ ok = false, error = env_error }, env_cx)
		end
		local name = if windows then "bun.exe" else "bun"
		local exe = on_path(name, env, dir)
		if not exe then
			if ShellEnv.config().mode == "shell" then
				exe = "bun" -- the selected shell's launcher resolves it, or reports it missing
			else
				exe = mise_shim(mise_installs(windows), name)
			end
		end
		if not exe then
			return done({
				ok = false,
				error = {
					code = "BUN_MISSING",
					message = "Bun was not found, and it reads folders and files for the navigator.",
					nextStep = "Install Bun (dev doctor lists it as a prerequisite). If it is installed, open dev settings to use an initialized shell environment, or start Tern from a shell where bun is on PATH.",
					details = {},
				},
			}, env_cx)
		end
		local argv = { exe, "-e", FS_SCRIPT }
		table.move(args, 1, #args, #argv + 1, argv)
		local child_env = table.clone(env)
		child_env.NO_COLOR, child_env.FORCE_COLOR = "1", "0"
		local ok, err = pcall(ShellEnv.run, argv, { cwd = dir, timeout_ms = READ_MS, env = child_env }, function(result: ProcessResult, cx: any)
			local answer = DevCli.decode(result)
			if answer.ok and type(answer.value) ~= "table" then
				answer = failure("BAD_OUTPUT", "Bun answered in an unexpected shape.")
			elseif answer.ok and type(answer.value.error) == "table" then
				local e = answer.value.error
				answer = { ok = false, error = { code = tostring(e.code or "ERROR"), message = Redaction.text(tostring(e.message or "The read failed.")), details = {} } }
			end
			done(answer, cx)
		end)
		if not ok then
			done(failure("SPAWN", "Tern could not start Bun (" .. exe .. ").", tostring(err)), env_cx)
		end
	end)
end

-- One page of directory `path`: { entries, total, offset }. `offset` (0-based, a multiple of 100 when asked in
-- pages) is clamped to the last page. An entry is { name, path, directory, modifiedAt?, link?, broken? } and only
-- this page's entries are stat'ed. A symbolic link sorts with the files (by its own name) and is `directory`
-- when its target is one; `broken` marks a link whose target is gone. `total` counts every entry.
function DevCli.read_dir(path: string, offset: number?, done: (Result, any) -> ())
	bun({ "dir", path, tostring(math.max(0, math.floor(offset or 0))), tostring(DIR_PAGE) }, path, function(r, cx)
		local v = r.value
		if r.ok and not (type(v.entries) == "table" and type(v.total) == "number") then
			r = failure("BAD_OUTPUT", "Bun listed the folder in an unexpected shape.")
		elseif r.ok then
			r = { ok = true, value = { entries = list(v.entries), total = v.total, offset = tonumber(v.offset) or 0 } }
		end
		done(r, cx)
	end)
end

-- ws.md without its frontmatter: the part a person reads.
local function manifest_body(text: string): string
	local body = string.gsub(string.gsub(text, "^\239\187\191", ""), "\r\n", "\n")
	if string.sub(body, 1, 4) == "---\n" then
		local _, stop = string.find(body, "\n%-%-%-[ \t]*\n", 4)
		if stop then
			body = string.sub(body, stop + 1)
		elseif string.find(body, "\n%-%-%-[ \t]*$", 4) then
			body = ""
		end
	end
	return (string.gsub(body, "^\n+", ""))
end

-- Workspace folder `path`'s ws.md: { text = the body, modifiedAt = Unix seconds }; a regular file under 256 KiB.
function DevCli.manifest(path: string, done: (Result, any) -> ())
	bun({ "file", join(path, "ws.md"), tostring(MANIFEST_MAX_BYTES) }, path, function(r, cx)
		if r.ok and type(r.value.text) == "string" then
			r = { ok = true, value = { text = manifest_body(r.value.text), modifiedAt = tonumber(r.value.modifiedAt) } }
		elseif r.ok then
			r = failure("BAD_OUTPUT", "Bun read ws.md in an unexpected shape.")
		elseif r.error.code == "ENOENT" then
			r = failure("ENOENT", "ws.md does not exist in this workspace.")
		end
		done(r, cx)
	end)
end

export type GitFolder = {
	remote: string?, -- fetch URL of origin, else of the first remote; nil: no remote at all
	branch: string?, -- nil: detached HEAD
	upstream: string?,
	ahead: number?, -- commits the upstream lacks; nil without an upstream
	commits: boolean, -- false: nothing committed yet
	changes: number, -- uncommitted (staged, unstaged, untracked) paths
}

local function git(path: string, args: { string }, done: (ProcessResult?, any) -> ())
	ShellEnv.resolve(path, function(env, err, env_cx)
		if err then return done(nil, env_cx) end
		local argv = { on_path(if tern.runtime.os == "windows" then "git.exe" else "git", env, path) or "git", "-C", path }
		table.move(args, 1, #args, #argv + 1, argv)
		local child_env = table.clone(env)
		child_env.GIT_OPTIONAL_LOCKS = "0"
		local ok = pcall(ShellEnv.run, argv, { cwd = path, timeout_ms = READ_MS, env = child_env }, function(r: ProcessResult, cx: any)
			done(if r.status == 0 and not r.timed_out then r else nil, cx)
		end)
		if not ok then done(nil, env_cx) end
	end)
end

-- What a git repository dev does not track holds that exists nowhere else: whether it has a remote, commits
-- the upstream lacks, uncommitted changes. Answers nil when git cannot read it (no git, a broken repository).
function DevCli.git_folder(path: string, done: (GitFolder?, any) -> ())
	git(path, { "remote", "-v" }, function(rr, cx)
		if not rr then
			return done(nil, cx)
		end
		local remote = nil
		for _, line in string.split(rr.stdout, "\n") do
			local name, url = string.match(line, "^(%S+)%s+(%S+)%s+%(fetch%)")
			if name and (remote == nil or name == "origin") then
				remote = url
			end
		end
		git(path, { "status", "--porcelain=v2", "--branch" }, function(sr, cx2)
			if not sr then
				return done(nil, cx2)
			end
			local out: GitFolder = { remote = remote, commits = true, changes = 0 }
			for _, line in string.split((string.gsub(sr.stdout, "\r", "")), "\n") do
				local head = string.match(line, "^# branch%.head (.+)$")
				local up = string.match(line, "^# branch%.upstream (.+)$")
				local ahead = string.match(line, "^# branch%.ab %+(%d+) ")
				if line == "# branch.oid (initial)" then
					out.commits = false
				elseif head then
					out.branch = if head == "(detached)" then nil else head
				elseif up then
					out.upstream = up
				elseif ahead then
					out.ahead = tonumber(ahead)
				elseif line ~= "" and string.sub(line, 1, 1) ~= "#" then
					out.changes += 1
				end
			end
			done(out, cx2)
		end)
	end)
end

-- When the newest commit of the repository at `path` was made (Unix seconds, author-independent commit time of
-- HEAD), or nil when git cannot say (no git, no commits). It says nothing about uncommitted edits.
function DevCli.last_commit(path: string, done: (number?, any) -> ())
	git(path, { "log", "-1", "--format=%ct" }, function(r, cx)
		done(if r then tonumber(string.match(r.stdout, "%d+")) else nil, cx)
	end)
end

-- ws.md's frontmatter with `description:` (and its continuation lines) replaced by `desc`, or nil and why.
function DevCli.with_description(text: string, desc: string): (string?, string?)
	local nl = if string.find(text, "\r\n", 1, true) then "\r\n" else "\n"
	local lines = string.split((string.gsub(text, "\r\n", "\n")), "\n")
	if lines[1] ~= "---" then
		return nil, "ws.md does not start with a frontmatter block"
	end
	local close = nil
	for i = 2, #lines do
		if lines[i] == "---" then
			close = i
			break
		end
	end
	if not close then
		return nil, "ws.md frontmatter has no closing ---"
	end
	local flat = string.gsub(string.gsub(desc, "%s+", " "), "^ ", "")
	flat = string.gsub(flat, " $", "")
	local line = "description: " .. tern.json.encode(flat)
	local out = {}
	local at, skipping = nil, false
	for i, l in lines do
		if i > 1 and i < close and string.match(l, "^description:") then
			at = #out + 1
			table.insert(out, line)
			skipping = true
		elseif skipping and i < close and (string.match(l, "^%s") or l == "") then
			-- continuation of the old value
		else
			skipping = false
			table.insert(out, l)
		end
	end
	if not at then
		local after = close
		for i = 2, close - 1 do
			if string.match(lines[i], "^name:") then
				after = i + 1
				break
			end
		end
		table.insert(out, after, line)
	end
	return table.concat(out, nl), nil
end

-- `i.path`: the workspace folder; `i.text`: the new description (whitespace folds to single spaces); `i.docs`:
-- the window's DocsCx. dev refuses to change a description through `ws init`, so this rewrites ws.md's
-- `description:` key. Through `docs`, an open ws.md buffer is edited in place (unsaved edits kept) and saved,
-- because dev reads the file on disk. Window half only.
function DevCli.set_description(i: { [string]: any }, done: (Result, any) -> ())
	local file = tostring(i.path) .. sep(tostring(i.path)) .. "ws.md"
	local docs = i.docs
	local function fail(code: string, message: string, detail: any)
		done(failure(code, message, if detail ~= nil then tostring(detail) else nil), nil)
	end
	docs:read(file):next(function(text, err)
		if err ~= nil or type(text) ~= "string" then
			return fail("FILE", "Could not read " .. file .. ".", err)
		end
		local updated, why = DevCli.with_description(text, tostring(i.text or ""))
		if not updated then
			return fail("MANIFEST_INVALID", "Description not changed: " .. tostring(why) .. ".", file)
		end
		docs:write(file, updated):next(function(_, werr)
			if werr ~= nil then
				return fail("FILE", "Could not write " .. file .. ".", werr)
			end
			docs:save(file):next(function(_, serr, cx)
				if serr ~= nil then
					return fail("FILE", "Could not save " .. file .. ".", serr)
				end
				done({ ok = true, value = { path = file } }, cx)
			end)
		end)
	end)
end

-- The command line a person would type for this operation, including its selected root.
function DevCli.describe(name: string, input: { [string]: any }?): string
	local op = OPS[name]
	if not op then
		return name
	end
	local out = { "dev" }
	local i = input or {}
	local words = op.argv(i)
	if not op.unrooted then option(words, i.root, "--root") end
	if op.tail then
		words = table.clone(words)
		table.insert(words, "--")
		for _, a in op.tail(input or {}) do
			table.insert(words, a)
		end
	end
	for _, a in words do
		if a == "" or string.find(a, "[%s\"']") then
			table.insert(out, '"' .. string.gsub(a, '"', '\\"') .. '"')
		else
			table.insert(out, a)
		end
	end
	return table.concat(out, " ")
end

return DevCli
