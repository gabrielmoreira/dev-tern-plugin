--!nonstrict
-- Consumer-visible runtime and refresh boundaries. Run from the plugin root: lune run test/reliability.luau
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
local function store(dev)
	return Store.new({ surface = "block", dev = dev, redraw = function() end, effect = function() end })
end
local missing = { code = "ENOENT", message = 'Executable not found in $PATH: "git"', details = { command = "git" } }

test("failed status retains prior observations as stale, not fresh health", function()
	local s = store({ status = function(_, done) done({ ok = false, error = missing }, nil) end })
	s.active_root = "/same-root"
	s.workspaces = { { name = "task", path = "/same-root/ws/task", mountCount = 1 } }
	local prior = { mounts = { { path = "lib", state = "dirty" } } }
	s.status.task = { data = prior, loading = false }
	s.checked.task = 1
	Store.check(s, nil, "task")
	assert(s.status.task.data == prior, "Failure must preserve the last successful mount observations")
	assert(s.status.task.error == missing and s.status.task.stale, "Preserved observations must be explicitly stale")
	assert(s.checked.task == 1, "A failed read must not advance the last successful check time")
	local label, tone = Store.health(s, s.workspaces[1])
	assert(label == "stale" and tone == "warning", "Cached data must not claim current clean or dirty health")
end)

test("same-root list failure retains prior lists and exposes staleness", function()
	local s = store({
		roots = function(_, done) done({ ok = true, value = {} }, nil) end,
		current = function(_, done) done({ ok = true, value = { root = "/same-root", source = "default" } }, nil) end,
		workspaces = function(_, done) done({ ok = false, error = missing }, nil) end,
		mirrors = function(_, done) done({ ok = false, error = missing }, nil) end,
		status = function(_, done) done({ ok = false, error = missing }, nil) end,
	})
	s.active_root = "/same-root"
	local prior = { { name = "task", path = "/same-root/ws/task", mountCount = 1 } }
	s.workspaces = prior
	s.mirrors = { { name = "lib", path = "/same-root/mirrors/lib" } }
	Store.refresh(s, nil, true)
	assert(s.workspaces == prior and #s.mirrors == 1, "A failed refresh must not replace prior same-root lists with an empty state")
	assert(s.workspaces_stale and s.mirrors_stale, "Both retained lists must be marked stale")
end)

test("root change cannot reuse same-named workspace observations", function()
	local s = store({
		roots = function(_, done) done({ ok = true, value = {} }, nil) end,
		current = function(_, done) done({ ok = true, value = { root = "/new-root", source = "default" } }, nil) end,
		workspaces = function(_, done) done({ ok = true, value = { { name = "task", path = "/new-root/ws/task", mountCount = 1 } } }, nil) end,
		mirrors = function(_, done) done({ ok = true, value = {} }, nil) end,
		status = function() end,
	})
	s.active_root = "/old-root"
	s.status.task = { data = { mounts = { { path = "old-root-only", state = "clean" } } } }
	Store.refresh(s, nil, true)
	assert(not s.status.task or s.status.task.data == nil, "The new root must not display observations from an identically named old workspace")
end)

test("initial root resolution preserves requested workspace navigation", function()
	local s = store({
		roots = function(_, done) done({ ok = true, value = {} }) end,
		current = function(_, done) done({ ok = true, value = { root = "/first-root" } }) end,
		workspaces = function(_, done) done({ ok = true, value = { { name = "task", path = "/first-root/ws/task", mountCount = 1 } } }) end,
		mirrors = function(_, done) done({ ok = true, value = {} }) end,
		status = function(_, done) done({ ok = true, value = { mounts = { { path = "lib", state = "clean" } } } }) end,
	})
	s.screen, s.selected = "ws", "task"
	Store.refresh(s, nil, true)
	assert(s.screen == "ws" and s.selected == "task", "Binding the first root must not turn a directly opened workspace into Home")
	assert(s.status.task and s.status.task.data, "The requested workspace must load against the resolved root")
end)

test("raw failure detail cannot surface a printed credential", function()
	local View = Shim.load(base .. "/view.luau")
	local s = store({})
	local secret = "ghp_thisIsAFakeTokenValue1234567890ab"
	s.failure = {
		label = "Read status",
		error = {
			code = "EXIT", message = "dev failed",
			detail = "error: gh auth token failed\nGITHUB_TOKEN=" .. secret .. "\nAuthorization: Bearer abc.def.ghi\n" .. string.rep("x", 400),
		},
		remedies = {},
	}
	local text = {}
	local function walk(node)
		if type(node) ~= "table" then return end
		local p = node.p or {}
		if type(p.text) == "string" then table.insert(text, p.text) end
		for _, key in { "spans", "head" } do
			for _, span in type(p[key]) == "table" and p[key] or {} do if span.t then table.insert(text, span.t) end end
		end
		for _, child in node.c or {} do walk(child) end
	end
	walk(View.render(s, {}))
	local visible = table.concat(text, "\n")
	assert(not string.find(visible, secret, 1, true), "A token printed by a provider CLI must never reach the error card")
	assert(not string.find(visible, "abc.def.ghi", 1, true), "A bearer value must not reach the error card")
	assert(string.find(visible, "gh auth token failed", 1, true), "Non-secret diagnostic context must survive redaction")
	assert(string.find(visible, "[redacted]", 1, true), "Redaction must leave a visible marker instead of silently dropping the line")
end)

test("stale mount cards stay visible with context and disabled mutations", function()
	local View = Shim.load(base .. "/view.luau")
	local s = store({})
	s.active_root, s.selected, s.screen = "/review-root", "task", "ws"
	s.workspaces = { { name = "task", path = "/review-root/ws/task", mountCount = 1 } }
	s.status.task = {
		stale = true, error = {
			code = "ENOENT", message = "git unavailable", nextStep = "Review the selected environment.",
			context = { operation = "status", executable = "/tools/dev", cwd = "/review-root/ws/task", root = "/review-root", environment = "inherited" },
		},
		data = { mounts = { { path = "cached-lib", state = "dirty", desired = { revision = { mode = "track", branch = "main" } } } } },
	}
	Store.dispatch(s, nil, "ws.tab", "repositories")
	local main = View.render(s, {})
	local text, remove = {}, nil
	local function walk(node)
		if type(node) ~= "table" then return end
		local p = node.p or {}
		if type(p.text) == "string" then table.insert(text, p.text) end
		for _, key in { "spans", "head" } do
			for _, span in type(p[key]) == "table" and p[key] or {} do
				if span.t then table.insert(text, span.t) end
			end
		end
		if p.actions and p.actions.click == "remove=task|cached-lib" then remove = p end
		for _, child_node in node.c or {} do walk(child_node) end
	end
	walk(main)
	local visible = table.concat(text, "\n")
	assert(string.find(visible, "cached-lib", 1, true), "A refresh failure must not erase the cached mount card")
	assert(string.find(visible, "/review-root/ws/task", 1, true) and string.find(visible, "/tools/dev", 1, true), "The failed operation's cwd and executable must be visible")
	assert(remove and remove.disabled ~= nil, "Cached observations must not enable a destructive mount action")
	Store.dispatch(s, nil, "remove.all", "task")
	assert(s.confirm == nil, "Cached observations must not authorize batch removal review")
end)

-- Only substitute the executable at the process boundary; child cwd/environment and adapter parsing stay real.
local tmp = base .. "/.local/reliability/runtime-fixture"
fs.writeDir(tmp)
fs.writeDir(tmp .. "/project-a")
fs.writeDir(tmp .. "/project-b")
local child = tmp .. "/probe.js"
fs.writeFile(child, [[
const op = process.argv[2];
if (op === 'doctor') {
  console.log(JSON.stringify({status:'error',root:{path:process.cwd(),exists:true,hasDevDir:true},tools:[{name:'git',required:true,available:false}],providerList:[],messages:['git missing'],checks:[{id:'tool:git',label:'git',status:'error',durationMs:1,message:'git missing'}]}));
  process.exit(1);
}
if (op === 'ws') {
  console.log(JSON.stringify({error:{code:'ENOENT',message:'git unavailable',details:{command:'git'}}}));
  process.exit(1);
}
console.log(JSON.stringify({root:process.cwd(),source:process.env.DEV_TERN_PROBE || 'inherited'}));
]])
local original_run = Shim.tern.process.run
local ShellEnv = Shim.load(base .. "/shellenv.luau")
local original_launch = ShellEnv.run
local bun = process.env.DEV_TERN_TEST_BUN or "bun"
Shim.env_override.DEV_TERN_BIN = bun
Shim.extra_env.DEV_TERN_BIN = bun
ShellEnv.run = function(argv, opts, done)
	if argv[1] == bun then
		local command = { bun, child }
		for i = 2, #argv do table.insert(command, argv[i]) end
		return original_launch(command, opts, done)
	end
	return original_launch(argv, opts, done)
end
local function call(op, input)
	local result
	Dev[op](input, function(r) result = r end)
	Shim.settle()
	assert(result ~= nil, "Operation did not settle")
	return result
end

test("CLI runs in its requested project context", function()
	local r = call("current", { root = tmp .. "/project-a" })
	assert(r.ok and Store.norm(r.value.root) == Store.norm(tmp .. "/project-a"), "Directory-dependent tool selection must use the requested project, not the plugin folder; actual=" .. tostring(r.value and r.value.root) .. " code=" .. tostring(r.error and r.error.code))
end)

test("nonzero doctor report remains a usable diagnostic report", function()
	local r = call("doctor", { root = tmp .. "/project-a" })
	assert(r.ok and r.value.status == "error", "Doctor exit1 with a structured report must not hide its successful and failed checks")
	assert(r.value.checks[1].id == "tool:git", "The reported failing stage must reach the consumer")
end)

test("CLI dependency errors expose operation context and safe guidance", function()
	local r = call("status", { root = tmp, cwd = tmp .. "/project-a", ws = "task" })
	assert(not r.ok and r.error.code == "ENOENT", "The semantic CLI error must survive")
	local c = r.error.context
	assert(c and c.operation == "status" and Store.norm(c.cwd) == Store.norm(tmp .. "/project-a"), "Failure must name the actual operation and working directory")
	assert(c.environment == "inherited" and type(r.error.nextStep) == "string", "Missing dependencies need an environment-specific remedy without executing it")
end)

test("batch removal uses the reviewed workspace execution directory", function()
	local s = store(Dev)
	s.active_root = tmp
	s.workspaces = { { name = "task", path = tmp .. "/project-a", mountCount = 1 } }
	s.status.task = { data = { mounts = { { path = "lib", state = "clean", observed = { isDirty = false } } } } }
	Store.dispatch(s, nil, "remove.all", "task")
	assert(s.confirm, "A fresh review must require confirmation")
	Store.dispatch(s, nil, "confirm.yes")
	Shim.settle()
	assert(s.failure and s.failure.error.context and Store.norm(s.failure.error.context.cwd) == Store.norm(tmp .. "/project-a"), "A refused batch operation must report the workspace's directory, not the root's toolchain")
end)

test("opt-in shell initialization runs prompt hooks per project and caches only in memory", function()
	local windows = process.os == "windows"
	local shell = process.env.DEV_TERN_TEST_SHELL or (if windows then "pwsh" else "/bin/bash")
	local adapter_run = Shim.tern.process.run
	local boots = 0
	Shim.tern.process.run = function(argv, opts, done)
		if argv[1] == shell and argv[2] == (if windows then "-NoLogo" else "-il") then
			boots += 1
			local safe = if windows then { shell, "-NoProfile", "-NoLogo", "-NoExit" } else { shell, "--noprofile", "--norc", "-i" }
			local options = table.clone(opts or {})
			local hook = if windows then "function global:prompt { $env:DEV_TERN_PROBE = 'profile-' + (Split-Path -Leaf $PWD.Path); 'fixture> ' }\n"
				else "PROMPT_COMMAND='export DEV_TERN_PROBE=profile-${PWD##*/}'\n"
			options.stdin = hook .. tostring(options.stdin or "")
			return original_run(safe, options, done)
		end
		return adapter_run(argv, opts, done)
	end
	Shim.kv.execution = { mode = "shell", kind = if windows then "pwsh" else "bash", shell = shell, revision = 1 }
	local a = call("current", { root = tmp .. "/project-a" })
	local b = call("current", { root = tmp .. "/project-b" })
	assert(a.ok and a.value.source == "profile-project-a", "An opted-in shell must apply its prompt initialization in project A; source=" .. tostring(a.value and a.value.source) .. " code=" .. tostring(a.error and a.error.code))
	assert(b.ok and b.value.source == "profile-project-b", "Environment must not leak project A's toolchain into project B")
	local again = call("current", { root = tmp .. "/project-a" })
	assert(again.ok and again.value.source == "profile-project-a" and boots == 2, "Repeated reads must reuse the same-context environment")
	assert(Shim.kv.execution.DEV_TERN_PROBE == nil, "Captured environment must not be persisted in plugin settings")
	Shim.kv.execution = { mode = "inherited", revision = 2 }
	local inherited = call("current", { root = tmp .. "/project-a" })
	assert(inherited.ok and inherited.value.source == "inherited" and boots == 2, "Disabling profile execution must immediately discard captured values")
	Shim.tern.process.run = adapter_run
end)

test("shared execution changes invalidate all pending environment consumers", function()
	local ShellEnv = Shim.load(base .. "/shellenv.luau")
	local adapter_run = Shim.tern.process.run
	local reply
	Shim.tern.process.run = function(_, _, done) reply = done end
	Shim.kv.execution = { mode = "shell", kind = "bash", shell = "/fixture/bash", revision = 20 }
	local results = {}
	ShellEnv.resolve("/pending-project", function(env, err) table.insert(results, { env = env, error = err }) end)
	ShellEnv.resolve("/pending-project", function(env, err) table.insert(results, { env = env, error = err }) end)
	-- Another VM writes shared kv without updating this VM's local cache revision.
	Shim.kv.execution = { mode = "inherited", revision = 21 }
	reply({ status = 0, stdout = string.char(30) .. "PATH=/fixture" .. string.char(0) .. string.char(31) })
	Shim.tern.process.run = adapter_run
	assert(#results == 2 and results[1].env == nil and results[1].error.code == "ENV_CHANGED" and results[2].error.code == "ENV_CHANGED", "Switching environment must discard an old capture even before another resolution runs in this VM")
end)

Shim.tern.process.run = original_run
ShellEnv.run = original_launch
if #failures > 0 then
	error(tostring(#failures) .. " reliability regressions failed: " .. table.concat(failures, ", "))
end
print("reliability boundaries passed")
