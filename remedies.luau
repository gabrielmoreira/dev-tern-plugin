--!nonstrict
-- What the UI may offer after dev refuses an operation. Keyed by (operation, error code), never by exit code
-- alone: one exit code covers dirty work, untrusted hooks, existing targets and unsafe removals, and each
-- needs its own answer. dev's `nextStep` is display text (it can hold placeholders such as `<usage>`), so it
-- is never turned into an action here. Nothing here forces.

local Remedies = {}

export type Remedy = {
	label: string,
	-- "run": run operation `op` with `input` (after `confirm`, when present); "refresh": reload lists;
	-- "select": show workspace `value`.
	kind: string,
	op: string?,
	input: { [string]: any }?,
	value: string?,
	variant: string?,
	confirm: { title: string, lines: { string }, tone: string }?,
}

local function with(input: { [string]: any }, key: string, value: any): { [string]: any }
	local out = {}
	for k, v in input do
		out[k] = v
	end
	out[key] = value
	return out
end

local function consent(op: string, input, err, title: string): Remedy
	local lines = { err.message }
	local d = err.details or {}
	if type(d.source) == "string" then
		table.insert(lines, "Repository: " .. d.source)
	end
	if type(d.hookName) == "string" then
		table.insert(lines, "Hook: " .. d.hookName)
	end
	table.insert(lines, "Allowing runs commands that repository declares, on this machine.")
	return {
		label = "Review and allow…",
		kind = "run",
		op = op,
		input = with(input, "consent", true),
		confirm = { title = title, lines = lines, tone = "warning" },
	}
end

local TRANSIENT = { NETWORK = true, RATE_LIMITED = true, TIMEOUT = true, FILE_LOCKED = true }
-- Safe to run again as they were.
local REPEATABLE = { update = true, sync_mirrors = true, sync_providers = true, status = true, pull_requests = true }

function Remedies.for_failure(op: string, input: { [string]: any }, err): { Remedy }
	local code = err.code
	local d = err.details or {}
	local out: { Remedy } = {}
	if op == "update" and code == "DIRTY_WORKTREE" and not input.autostash then
		table.insert(out, {
			label = "Update with --autostash…",
			kind = "run",
			op = "update",
			input = with(input, "autostash", true),
			variant = "primary",
			confirm = {
				title = "Stash local changes and update?",
				lines = {
					"dev stashes the uncommitted changes, fast-forwards, then applies them back.",
					"The stash entry is kept as a backup.",
				},
				tone = "warning",
			},
		})
	elseif (op == "update" or op == "add") and code == "UNTRUSTED_HOOK_BLOCKED" then
		table.insert(out, consent(op, input, err, "Allow this repository's hook?"))
	elseif (op == "create" or op == "setup") and code == "SETUP_BLOCKED" then
		-- After `create` the workspace exists; only its setup is left to run.
		local ws = if op == "setup" then input.ws else (d.workspaceName or d.name or input.name)
		table.insert(out, consent("setup", { root = input.root, ws = tostring(ws) }, err, "Run setup commands dev does not trust?"))
	elseif op == "create" and code == "WORKSPACE_ALREADY_EXISTS" then
		local name = d.name or d.workspaceName or input.name
		if type(name) == "string" then
			table.insert(out, { label = "Show existing workspace", kind = "select", value = name, variant = "primary" })
		end
	elseif code == "WORKSPACE_NOT_FOUND" or code == "MANIFEST_NOT_FOUND" then
		table.insert(out, { label = "Reload list", kind = "refresh" })
	end
	if TRANSIENT[code] and REPEATABLE[op] then
		table.insert(out, { label = "Try again", kind = "run", op = op, input = input })
	end
	return out
end

return Remedies
