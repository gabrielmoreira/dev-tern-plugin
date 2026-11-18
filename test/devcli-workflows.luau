--!nonstrict
-- Port contracts run the real argv/JSON adapters with only process execution replaced.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
base = string.gsub(base, "/$", "")
Shim.env_override.DEV_TERN_BIN = "fixture-dev"
local output = "[]"
local launched = nil
local old_run = Shim.tern.process.run
Shim.tern.process.run = function(argv, _, done)
	launched = table.clone(argv)
	done({ status = 0, stdout = output, stderr = "", timed_out = false }, nil)
end
local Dev = Shim.load(base .. "/devcli.luau")
local function invoke(op, input, json)
	output = json
	local result
	Dev[op](input or {}, function(r) result = r end)
	assert(result and result.ok, op .. " failed")
	return result.value, launched
end

local inventory = [[
[
 {"name":"Same","url":"https://one.test/Same","disabled":false,"default_branch":"main","project":"one","secret":"drop"},
 {"name":"Same","url":"ssh://two.test/Same","disabled":false,"organization":"two"},
 {"name":"Hidden","url":"https://disabled.test/Hidden","disabled":true}
]
]]
local rows = invoke("catalog", { root = "C:/root" }, inventory)
assert(#rows == 2 and rows[1].url == "https://one.test/Same" and rows[2].url == "ssh://two.test/Same")
assert(rows[1].default_branch == "main" and rows[1].project == "one" and rows[1].secret == nil)
assert(launched[2] == "sync" and launched[3] == "inventory" and launched[4] == "--offline")

local detail = invoke("workset", { name = "starter", root = "C:/root" }, [[{"description":"desc","members":[{"source":"https://repo.test/a"}]}]])
assert(detail.name == "starter" and detail.description == "desc" and detail.members[1].source == "https://repo.test/a")

local saved, save_argv = invoke("save_workset", {
	name = "renamed", original_name = "starter", root = "C:/root",
	definition = { description = "desc", members = { { source = "https://repo.test/a", setup = "skip" } } },
}, [[{"name":"renamed","description":"desc","members":[]}]] )
assert(saved.name == "renamed")
local encoded = nil
for i, arg in save_argv do
	if arg == "--definition-json" then encoded = save_argv[i + 1] end
end
assert(encoded and string.find(encoded, '"source":"https://repo.test/a"', 1, true))
assert(table.find(save_argv, "--original") ~= nil)

local plan = invoke("create_plan", { root = "C:/root", form = {
	source = "url", url = "https://host.test/org/repo/pull/7", name = "reviewed-name", desc = "desc", setup = false,
} }, [[{"name":"reviewed-name","description":"desc","path":"C:/root/ws/reviewed-name","exists":false,"mounts":[{"source":"https://host.test/org/repo","branch":"topic"}]}]])
assert(plan.name == "reviewed-name" and plan.mounts[1].branch == "topic")
assert(table.find(launched, "--dry-run") ~= nil and table.find(launched, "--name") ~= nil)
assert(table.find(launched, "--setup") == nil, "A boolean must not become a shell setup command")

invoke("create_plan", { root = "C:/root", form = {
	source = "repositories", name = "repo-plan", mounts = {}, setup = "custom",
} }, [[{"name":"repo-plan","description":"","path":"C:/root/ws/repo-plan","exists":false,"mounts":[]}]] )
assert(launched[4] == "repo-plan" and table.find(launched, "--name") == nil)
assert(launched[table.find(launched, "--setup") + 1] == "custom")

invoke("create_plan", { root = "C:/root", form = {
	source = "label", name = "labels-plan", labels = { "alpha", "beta" },
} }, [[{"name":"labels-plan","description":"","path":"C:/root/ws/labels-plan","exists":false,"mounts":[]}]] )
local label_flag = table.find(launched, "--label")
assert(label_flag ~= nil and launched[label_flag + 1] == "alpha,beta")
assert(table.find(launched, "--name") == nil)
invoke("create_plan", { root = "C:/root", form = {
	source = "workset", name = "workset-plan", workset = "starter",
} }, [[{"name":"workset-plan","description":"","path":"C:/root/ws/workset-plan","exists":false,"mounts":[]}]] )
assert(launched[4] == "workset-plan" and table.find(launched, "--name") == nil)
assert(launched[table.find(launched, "--workset") + 1] == "starter")

local reviewed_repositories = { { source = "https://one.test/repo", branch = "topic", path = "repo", setup = "skip" }, { source = "C:/src/local", path = "local" } }
invoke("create", { root = "C:/root", name = "reviewed-name", desc = "desc", repositories = reviewed_repositories }, [[{"name":"reviewed-name","created":true}]])
local mount_arg = nil
for i, arg in launched do if arg == "--mounts-json" then mount_arg = launched[i + 1] end end
assert(mount_arg and string.find(mount_arg, '"branch":"topic"', 1, true) and string.find(mount_arg, '"source":"C:/src/local"', 1, true))
assert(table.find(launched, "--yes") ~= nil)

invoke("work_items", { root = "C:/root", live = true, provider = "azure", project = "alpha" }, "[]")
assert(table.find(launched, "--provider") ~= nil and table.find(launched, "--project") ~= nil)

Shim.tern.process.run = old_run
Shim.env_override.DEV_TERN_BIN = nil
print("devcli workflow tests passed")
