--!nonstrict
-- Real CLI child under a synthetic captured environment; no profiles or credential tools run.
local process = require("@lune/process")
local fs = require("@lune/fs")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/"):gsub("/$", "")
local Dev = Shim.load(base .. "/devcli.luau")
local cwd = base .. "/.local/reliability/environment-fixture/space ação"
fs.writeDir(cwd)
fs.writeFile(cwd .. "/current", [[
console.log(JSON.stringify({root:process.cwd(),source:JSON.stringify({
  removed:process.env.REVIEW_INHERITED_SECRET === undefined,
  captured:process.env.REVIEW_CAPTURED_VALUE,
  identity:process.env.TERN_REVIEW_ID,
  platformValue:process.env["ProgramFiles(x86)"],
  argv:process.argv.slice(2)
})}));
if (process.env.REVIEW_TRANSPORT_TEST) {
  process.stderr.write("erro ação 日本\n");
  process.exitCode = 17;
}
]])
local windows = process.os == "windows"
local kind = process.env.DEV_TERN_TEST_KIND or (if windows then "pwsh" else "bash")
local shell = process.env.DEV_TERN_TEST_SHELL or (if kind == "pwsh" then "pwsh" elseif kind == "bash" then "/bin/bash" else "/bin/zsh")
local bun = process.env.DEV_TERN_TEST_BUN or "bun"
local snapshot = {
	[if windows then "Path" else "PATH"] = process.env.PATH or process.env.Path or "",
	DEV_TERN_BIN = bun,
	REVIEW_CAPTURED_VALUE = "ação 日本",
}
if windows then snapshot["ProgramFiles(x86)"] = "synthetic-platform-directory" end
-- Native executable startup on Windows still needs these non-secret platform variables.
for _, key in { "SystemRoot", "WINDIR", "TEMP", "TMP" } do
	if process.env[key] then snapshot[key] = process.env[key] end
end
Shim.kv.execution = { mode = "shell", kind = kind, shell = shell, revision = 90 }
Shim.extra_env.REVIEW_INHERITED_SECRET = "synthetic-parent-value"
Shim.extra_env.TERN_REVIEW_ID = "caller-identity"
local original = Shim.tern.process.run
Shim.tern.process.run = function(argv, opts, done)
	if argv[1] == shell and argv[2] == (if kind == "pwsh" then "-NoLogo" else "-il") then
		local payload = if kind == "pwsh" then Shim.tern.json.encode(snapshot) else ""
		if kind ~= "pwsh" then for key, value in snapshot do payload ..= key .. "=" .. value .. string.char(0) end end
		return done({ status = 0, stdout = string.char(30) .. payload .. string.char(31), stderr = "", timed_out = false }, Shim.cx)
	end
	return original(argv, opts, done)
end
local result
Dev.current({ root = cwd, cwd = cwd }, function(r) result = r end)
Shim.settle()
assert(result and result.ok, "Fixture CLI must return JSON before environment assertions: " .. tostring(result and result.error and result.error.code) .. " " .. tostring(result and result.error and result.error.detail))
local facts = Shim.tern.json.decode(result.value.source)
assert(facts.removed, "A variable removed by the initialization shell reappeared in the CLI child")
assert(facts.captured == "ação 日本", "Captured Unicode environment value was not preserved")
assert(facts.identity == "caller-identity", "The caller's Tern routing identity must survive environment replacement")
assert(facts.platformValue == snapshot["ProgramFiles(x86)"], "Windows environment keys that are not shell identifiers must survive")
assert(string.lower(string.gsub(result.value.root, "\\", "/")) == string.lower(cwd), "The isolated environment must retain the requested working directory")
print("PASS CLI child uses the captured environment without resurrecting inherited variables")

local arguments = { "", "space ação 日本", [[quote'"inside]], [[C:\folder\]], [[C:\folder\\\"quoted"\]], "line\nbreak" }
local argv = { bun, cwd .. "/current" }
for _, value in arguments do table.insert(argv, value) end
snapshot.REVIEW_TRANSPORT_TEST = "yes"
local direct
Shim.load(base .. "/shellenv.luau").run(argv, { cwd = cwd, env = snapshot, timeout_ms = 5000 }, function(r) direct = r end)
Shim.settle()
assert(direct and direct.status == 17 and not direct.timed_out, "The launcher must preserve the child's exit status")
assert(direct.stderr == "erro ação 日本\n", "The launcher must preserve stderr")
local received = Shim.tern.json.decode(Shim.tern.json.decode(direct.stdout).source).argv
assert(#received == #arguments, "The launcher changed the number of arguments")
for i, value in arguments do assert(received[i] == value, "The launcher changed argument " .. i) end
print("PASS CLI child preserves empty, quoted, Unicode and newline arguments, stderr and exit status")
