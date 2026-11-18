-- Focused PR presentation edge cases. Run: lune run test/pr-presentation.luau
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Store = Shim.load(base .. "/store.luau")
local View = Shim.load(base .. "/view.luau")

local function state()
	local s = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end })
	s.screen = "prs"
	s.pages = s.pages or { prs = 1 }
	s.pr_query = { scope = "mine", status = "open" }
	return s
end

local function inspect(node, acc)
	acc = acc or { text = {}, keys = {}, actions = {} }
	if type(node) ~= "table" then
		if type(node) == "string" then table.insert(acc.text, node) end
		return acc
	end
	local p = node.p or {}
	if p.key then table.insert(acc.keys, p.key) end
	if p.actions and p.actions.click then acc.actions[p.actions.click] = true end
	if p.title then table.insert(acc.text, tostring(p.title)) end
	for _, span in p.spans or {} do inspect(span.t, acc) end
	if p.text then inspect(p.text, acc) end
	for key, value in node do
		if key ~= "p" and key ~= "c" then inspect(value, acc) end
	end
	for _, child in node.c or {} do inspect(child, acc) end
	return acc
end

local function iso(epoch)
	return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local s = state()
local now = os.time()
s.prs = {
	{ id = 42, title = "A change", repository = "api", project = "North", provider = "ado", author = "Ana", sourceBranch = "feature", targetBranch = "main", url = "https://example.test/42", createdAt = iso(now - 3605), updatedAt = iso(now - 125) },
	{ id = 42, title = "Same ID elsewhere", repository = "api", project = "South", provider = "ado", createdAt = "0001-01-01T00:00:00Z", updatedAt = "not-a-date" },
	{ id = 42, title = "Other tenant and repository", tenant = "org-b", repository = "docs", project = "North", provider = "ado" },
	{ id = 43, title = "Bad creation date", repository = "infra", createdAt = "2026-02-31T00:00:00Z", updatedAt = "0001-01-01T00:00:00Z" },
}
local rendered = inspect((View.render(s, {})))
local all_text = table.concat(rendered.text, "\n")
assert(string.find(all_text, "#42", 1, true), "PR rows must prominently render their ID")
assert(string.find(all_text, "Created 1h", 1, true) and string.find(all_text, "Updated 2m", 1, true), "Valid creation and update timestamps get compact independent ages")
assert(not string.find(all_text, "0001-01-01", 1, true) and not string.find(all_text, "Created 0m", 1, true), "Invalid and provider-sentinel dates must not fabricate ages")
local seen = {}
for _, key in rendered.keys do
	if string.sub(key, 1, 3) == "pr:" then
		assert(not seen[key], "Same PR IDs in distinct projects require unique row keys")
		seen[key] = true
	end
end
assert(seen["pr::ado:North:api:42"] and seen["pr::ado:South:api:42"] and seen["pr:org-b:ado:North:docs:42"], "Row identity includes tenant, provider, project, repository, and PR ID")
assert(rendered.actions["pr=https://example.test/42"] and rendered.actions["pr.checkout=https://example.test/42"], "PR rows retain detail and checkout actions")

local filtered = state()
filtered.prs = s.prs
filtered.filter = "feature"
local filtered_tree = inspect((View.render(filtered, {})))
assert(filtered_tree.actions["pr=https://example.test/42"] and filtered_tree.actions["pr.checkout=https://example.test/42"], "Text-filtered results retain existing actions")
assert(string.find(table.concat(filtered_tree.text, "\n"), "Created 1h", 1, true), "Text-filtered results retain timestamp presentation")

local utc = os.date("!%Y-%m-%dT%H:%M:%S", now - 3605)
local y, m, d, h, minute, second = string.match(utc, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
if tonumber(h) < 22 then
	local local_plus_two = string.format("%s-%s-%sT%02d:%s:%s+02:00", y, m, d, (tonumber(h) + 2) % 24, minute, second)
	s.prs = { { id = 44, title = "Offset", createdAt = iso(now - 3605), updatedAt = local_plus_two } }
	local offset_text = table.concat(inspect((View.render(s, {}))).text, "\n")
	assert(string.find(offset_text, "Updated 1h", 1, true), "Timezone offsets preserve the represented instant")
end

s.screen = "pr"
s.pr = { data = { id = 42, title = "Detail", repository = "api", project = "North", createdAt = iso(now - 3605), updatedAt = iso(now - 125), url = "https://example.test/42" } }
local detail = inspect((View.render(s, {})))
local detail_text = table.concat(detail.text, "\n")
assert(string.find(detail_text, "#42", 1, true) and string.find(detail_text, iso(now - 3605), 1, true) and string.find(detail_text, iso(now - 125), 1, true), "Detail exposes the ID and full absolute timestamps")
print("PR presentation passed")

s.pr.data.updatedAt = nil
local missing_update = table.concat(inspect((View.render(s, {}))).text, "\n")
assert(string.find(missing_update, "Not reported", 1, true), "Absent provider update time is explicit, not a fabricated activity age")
