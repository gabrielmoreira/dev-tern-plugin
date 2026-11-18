--!nonstrict
-- Inject only the SDK's documented direct-process kill; launchers and their children are real.
local process = require("@lune/process")
local fs = require("@lune/fs")
local Shim = require("./shim")
if process.os ~= "windows" then print("SKIP Windows captured-environment process lifetime") return end
local base = string.gsub(process.cwd, "\\", "/"):gsub("/$", "")
local bun = process.env.DEV_TERN_TEST_BUN or "bun"
local kind = process.env.DEV_TERN_TEST_KIND or "pwsh"
local shell = process.env.DEV_TERN_TEST_SHELL or (process.env.ProgramFiles .. "/PowerShell/7/pwsh.exe")
Shim.kv.execution = { mode = "shell", kind = kind, shell = shell, revision = 91 }
local ShellEnv = Shim.load(base .. "/shellenv.luau")
local worker = [=[
import { spawn } from "node:child_process";
import { writeFileSync, appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
const dir = process.env.REVIEW_LIFETIME_DIR;
const grand = process.env.REVIEW_LIFETIME_GRAND === "yes";
writeFileSync(join(dir, grand ? "grand.pid" : "parent.pid"), String(process.pid));
const beat = () => appendFileSync(join(dir, grand ? "grand.beats" : "parent.beats"), ".");
beat();
if (!grand) {
  const child = spawn(process.execPath, [process.argv[1]], {
    env: { ...process.env, REVIEW_LIFETIME_GRAND: "yes" }, stdio: "ignore", windowsHide: true, detached: true,
  });
  child.unref();
}
setInterval(() => {
  beat();
  if (!grand && process.env.REVIEW_LIFETIME_MODE === "normal" && existsSync(join(dir, "grand.beats"))) process.exit(17);
}, 20);
]=]
local driver = [=[
import { spawn } from "node:child_process";
import { existsSync, readFileSync, rmSync, realpathSync } from "node:fs";
import { resolve, join } from "node:path";
const input = JSON.parse(await new Response(process.stdin).text());
const dir = realpathSync(input.dir);
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const alive = pid => { if (!pid) return false; try { process.kill(pid, 0); return true; } catch { return false; } };
const pid = name => existsSync(join(dir, name + ".pid")) ? Number(readFileSync(join(dir, name + ".pid"), "utf8")) : 0;
const beats = () => ["parent", "grand"].map(name => existsSync(join(dir, name + ".beats")) ? readFileSync(join(dir, name + ".beats"), "utf8").length : 0);
let launcher, facts;
try {
  const deadline = Date.now() + input.timeout_ms;
  launcher = spawn(input.argv[0], input.argv.slice(1), {
    cwd: input.cwd, env: { ...process.env, ...input.env }, stdio: ["pipe", "ignore", "pipe"], windowsHide: true,
  });
  let error = "";
  launcher.stderr.setEncoding("utf8");
  launcher.stderr.on("data", value => error += value);
  const ended = new Promise(resolve => launcher.once("exit", (code, signal) => resolve({code, signal})));
  launcher.stdin.end(input.stdin);
  while (!(existsSync(join(dir, "parent.beats")) && existsSync(join(dir, "grand.beats")))) {
    if (launcher.exitCode !== null || Date.now() >= deadline) throw new Error("Workers did not start: " + error);
    await wait(10);
  }
  if (input.mode === "timeout") {
    while (Date.now() < deadline) await wait(Math.min(10, deadline - Date.now()));
    if (!launcher.kill()) throw new Error("Could not inject the SDK direct-process timeout");
  }
  let stopWaiting;
  const outcome = await Promise.race([ended, new Promise((_, reject) => {
    stopWaiting = setTimeout(() => reject(new Error("Launcher did not exit")), 5000);
  })]).finally(() => clearTimeout(stopWaiting));
  if (input.mode === "timeout") {
    const limit = Date.now() + 1000;
    while ((alive(pid("parent")) || alive(pid("grand"))) && Date.now() < limit) await wait(10);
  }
  const before = beats();
  await wait(150);
  const after = beats();
  facts = { code: outcome.code, parentAlive: alive(pid("parent")), grandAlive: alive(pid("grand")), changed: before.some((value, i) => value !== after[i]) };
} catch (error) {
  facts = { fixtureError: String(error) };
} finally {
  if (launcher && launcher.exitCode === null) launcher.kill();
  for (const name of ["parent", "grand"]) { const id = pid(name); if (alive(id)) process.kill(id, "SIGKILL"); }
  const limit = Date.now() + 2000;
  while ((alive(pid("parent")) || alive(pid("grand"))) && Date.now() < limit) await wait(10);
  if (alive(pid("parent")) || alive(pid("grand"))) throw new Error("Owned worker cleanup failed");
  const parent = realpathSync(resolve(".local/reliability"));
  if (!dir.startsWith(parent + "\\") && !dir.startsWith(parent + "/")) throw new Error("Refusing fixture cleanup outside the test directory");
  rmSync(dir, { recursive: true });
}
console.log(JSON.stringify(facts));
]=]
local failures = 0
for _, mode in { "timeout", "normal" } do
	local made = process.exec(bun, { "-e", [[const fs=require('node:fs');fs.mkdirSync('.local/reliability',{recursive:true});console.log(fs.mkdtempSync(require('node:path').resolve('.local/reliability/lifetime-')));]] }, { cwd = base })
	assert(made.ok, "Could not create an isolated lifetime fixture")
	local dir = string.gsub(made.stdout, "%s+$", "")
	fs.writeFile(dir .. "/worker.mjs", worker)
	local env = { Path = process.env.PATH or process.env.Path, REVIEW_LIFETIME_DIR = dir, REVIEW_LIFETIME_MODE = mode }
	for _, key in { "SystemRoot", "WINDIR", "TEMP", "TMP" } do if process.env[key] then env[key] = process.env[key] end end
	Shim.tern.process.run = function(argv, opts, done)
		local child = process.create(bun, { "-e", driver }, { cwd = base })
		child.stdin:write(Shim.tern.json.encode({ argv = argv, cwd = opts.cwd, env = opts.env, stdin = opts.stdin, timeout_ms = opts.timeout_ms, mode = mode, dir = dir }))
		child.stdin:close()
		local stdout = child.stdout:readToEnd()
		local stderr = child.stderr:readToEnd()
		assert(child:status().ok, "Lifetime driver failed: " .. stderr)
		local facts = Shim.tern.json.decode(stdout)
		assert(not facts.fixtureError, facts.fixtureError)
		done(facts)
	end
	local result
	ShellEnv.run({ bun, dir .. "/worker.mjs" }, { cwd = dir, env = env, timeout_ms = 3000 }, function(r) result = r end)
	local ok = if mode == "timeout" then not result.parentAlive and not result.grandAlive and not result.changed else result.code == 17 and result.grandAlive and result.changed
	if ok then
		print("PASS " .. (if mode == "timeout" then "timed-out launcher leaves no child, descendant or continued writes" else "normally completed command preserves intentionally backgrounded work"))
	else
		failures += 1
		print("FAIL " .. mode .. ": " .. Shim.tern.json.encode(result))
	end
end
assert(failures == 0, tostring(failures) .. " captured-environment lifetime regressions failed")
