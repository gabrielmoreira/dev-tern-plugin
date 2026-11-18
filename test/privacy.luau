--!nonstrict
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/"):gsub("/$", "")
local View = Shim.load(base .. "/view.luau")
local Dev = Shim.load(base .. "/devcli.luau")
local failures = {}
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then print("PASS " .. name) else table.insert(failures, name); print("FAIL " .. name .. ": " .. tostring(why)) end
end
local function text(node, out)
	if type(node) ~= "table" then return end
	local p = node.p or {}
	if p.text then table.insert(out, tostring(p.text)) end
	for _, key in { "spans", "head" } do
		for _, span in p[key] or {} do if span.t then table.insert(out, span.t) end end
	end
	for _, action in p.actions or {} do table.insert(out, tostring(action)) end
	for _, child in node.c or {} do text(child, out) end
end
local function rendered(error)
	local out = {}
	for _, node in View.error_body(error) do text(node, out) end
	return table.concat(out, "\n")
end
for _, case in {
	{ "uppercase assignment", "PASSWORD=reviewSynthetic123" },
	{ "mixed case assignment", "aPi_ToKeN=reviewSynthetic123" },
	{ "quoted assignment", '"CLIENT_SECRET": "reviewSynthetic123 with spaces"' },
	{ "PAT assignment", "AZURE_DEVOPS_PAT=reviewSynthetic123" },
	{ "Basic authentication", "Authorization: Basic reviewSynthetic123" },
	{ "URL credentials", "https://user:reviewSynthetic123@example.invalid/repository" },
	{ "fine-grained token", "github_pat_fake_reviewSynthetic123_suffix" },
} do
	for _, field in { "message", "nextStep", "detail" } do
		test(field .. " hides " .. case[1], function()
			local e = { message = "Hook failed; inspect the repository setup." }
			e[field] = case[2]
			local visible = rendered(e)
			assert(not string.find(visible, "reviewSynthetic123", 1, true), "Credential value reached the error presentation")
			assert(string.find(visible, "[redacted]", 1, true), "A hidden credential needs a visible redaction marker")
		end)
	end
end
test("redaction keeps non-secret error guidance", function()
	local visible = rendered({ message = "Hook failed: PASSWORD=reviewSynthetic123", nextStep = "Inspect the repository setup." })
	assert(string.find(visible, "Hook failed", 1, true) and string.find(visible, "Inspect the repository setup.", 1, true), "Useful diagnostic context was lost")
end)
test("hook error reaches remedies without its printed credential", function()
	local original = Shim.tern.process.run
	Shim.tern.process.run = function(_, _, done)
		done({ status = 1, stdout = Shim.tern.json.encode({ error = { code = "HOOK_FAILED", message = "Hook failed: PASSWORD=reviewSynthetic123", nextStep = "Inspect the setup." } }), stderr = "", timed_out = false })
	end
	local result
	Dev.update({ root = base, ws = "task" }, function(r) result = r end)
	Shim.tern.process.run = original
	assert(result and not result.ok and result.error.code == "HOOK_FAILED", "Semantic hook failure was lost")
	assert(not string.find(result.error.message, "reviewSynthetic123", 1, true), "Raw hook output escaped the adapter presentation boundary")
end)
test("confirmation command identifies the root it will change", function()
	local command = Dev.describe("update", { root = "/review root", ws = "task", rebase = true })
	assert(string.find(command, '--root "/review root"', 1, true), "Copied confirmation command can act on the default root")
	assert(string.find(command, "--rebase", 1, true), "The reviewed update flag was omitted")
end)
test("a failed PR read shows the error instead of an endless cache spinner", function()
	local Store = Shim.load(base .. "/store.luau")
	local s = Store.new({ surface = "block", dev = Dev, redraw = function() end, effect = function() end })
	s.screen = "prs"
	s.prs_error = { code = "NETWORK", message = "Offline; retry the pull request list.", details = {} }
	local out = {}
	text(View.render(s, {}), out)
	local visible = table.concat(out, "\n")
	assert(string.find(visible, "Offline; retry the pull request list.", 1, true), "The failed PR read must expose its cause")
	assert(not string.find(visible, "Reading the cache", 1, true), "A completed failed read must not spin forever")
end)
for _, surface in { "failure", "card" } do
	test("copy error details retains safe diagnostics from " .. surface, function()
		local Store = Shim.load(base .. "/store.luau")
		local copied
		local s = Store.new({
			surface = "block", dev = Dev, redraw = function() end,
			effect = function(_, kind, data) if kind == "copy" then copied = data.text end end,
		})
		local e = {
			code = "INTERACTION_REQUIRED", message = "Azure DevOps provider is required.",
			context = {
				operation = "work_items", executable = "/tools/dev", cwd = "/review/root", root = "/review/root",
				environment = "inherited", durationMs = 4368,
				env = { PRIVATE_VALUE = "mustNotCopyEnvironment" },
			},
			details = { field = "provider", choices = { "ado-one", "ado-two" }, token = "mustNotCopyDetails" },
			detail = "Provider selection stopped.\nPASSWORD=reviewSynthetic123",
			nextStep = "dev wi --refresh --provider <id>",
		}
		if surface == "failure" then
			s.failure = { label = "List work items", error = e, remedies = {} }
		else
			s.screen, s.prs_error = "prs", e
		end
		local action
		local function find(node)
			if type(node) ~= "table" then return end
			local click = (node.p or {}).actions
			click = click and click.click
			if type(click) == "string" and string.find(click, "^copy=") and string.find(click, "INTERACTION_REQUIRED", 1, true) then action = click end
			for _, child in node.c or {} do find(child) end
		end
		find(View.render(s, {}))
		assert(action, "The error needs a Copy error details action, not only Copy suggestion")
		Store.dispatch(s, nil, "copy", string.sub(action, 6))
		for _, value in {
			"INTERACTION_REQUIRED", "Azure DevOps provider is required.", "work_items", "/tools/dev",
			"/review/root", "inherited", "4368 ms", "ado-one", "ado-two",
			"Provider selection stopped.", "dev wi --refresh --provider <id>", "[redacted]",
		} do
			assert(copied and string.find(copied, value, 1, true), "Copied diagnostics lost " .. value)
		end
		for _, secret in { "reviewSynthetic123", "mustNotCopyEnvironment", "mustNotCopyDetails" } do
			assert(not string.find(copied, secret, 1, true), "Copied diagnostics disclosed " .. secret)
		end
	end)
end

if #failures > 0 then error(tostring(#failures) .. " privacy contracts failed: " .. table.concat(failures, ", ")) end
print("privacy contracts passed")
