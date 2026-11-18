--!nonstrict
-- A work item opened from the list keeps its tenant, project and id from the rendered Details action through the
-- store to the dev argv. Run: lune run test/work-item-identity.luau
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
base = string.gsub(base, "/$", "")
Shim.env_override.DEV_TERN_BIN = "fixture-dev"

local TENANT_A, TENANT_B = "dev.azure.com/example-a", "dev.azure.com/example-b"
local SHARED, ODD = "Shared Project", "Pipe|Name 100%"

local runs = {}
local function flag_value(argv, name: string)
	local at = table.find(argv, name)
	return if at then argv[at + 1] else nil
end

-- A cache with the same numeric ID in several namespaces. A `wi view` that does not name the namespace gets a
-- record nobody asked for, so a first-provider fallback shows up as a wrong title.
local CACHE = {
	[TENANT_A .. "|" .. SHARED .. "|7"] = { id = 7, tenant = TENANT_A, project = SHARED, title = "Alpha record", state = "Active" },
	[TENANT_B .. "|" .. SHARED .. "|7"] = { id = 7, tenant = TENANT_B, project = SHARED, title = "Beta record", state = "New" },
	[TENANT_A .. "|" .. ODD .. "|7"] = { id = 7, tenant = TENANT_A, project = ODD, title = "Gamma record", state = "Closed" },
}
Shim.tern.process.run = function(argv, _, done)
	table.insert(runs, table.clone(argv))
	local key = tostring(flag_value(argv, "--tenant")) .. "|" .. tostring(flag_value(argv, "--project")) .. "|" .. tostring(argv[4])
	local record = CACHE[key] or { id = tonumber(argv[4]), tenant = "first-provider", project = "first-project", title = "WRONG: default provider record" }
	done({ status = 0, stdout = Shim.tern.json.encode(record), stderr = "", timed_out = false }, nil)
end

local Store = Shim.load(base .. "/store.luau")
local View = Shim.load(base .. "/view.luau")
local Dev = Shim.load(base .. "/devcli.luau")

local failures = 0
local function check(ok, message)
	print((if ok then "PASS " else "FAIL ") .. message)
	if not ok then failures += 1 end
end

local function new_store(dev)
	local s = Store.new({ surface = "block", dev = dev, redraw = function() end, effect = function() end })
	s.active_root = "C:/root"
	s.screen = "wis"
	s.pages = s.pages or { wis = 1 }
	s.wis = {
		{ id = 7, tenant = TENANT_A, project = SHARED, title = "Alpha record", type = "Bug", state = "Active", url = "https://example.test/a/7" },
		{ id = 7, tenant = TENANT_B, project = SHARED, title = "Beta record", type = "Bug", state = "New", url = "https://example.test/b/7" },
		{ id = 7, tenant = TENANT_A, project = ODD, title = "Gamma record", type = "Task", state = "Closed", url = "https://example.test/c/7" },
		{ id = 8, title = "No namespace", type = "Task", state = "New", url = "https://example.test/d/8" },
	}
	return s
end

-- Rendered work-item rows: { key, details = action string or nil, disabled = Details disabled reason }.
local function rendered_rows(s)
	local out = {}
	local function details_of(node, found)
		if type(node) ~= "table" then return end
		local p = node.p or {}
		local click = type(p.actions) == "table" and p.actions.click
		if type(click) == "string" and (click == "wi" or string.sub(click, 1, 3) == "wi=") then
			found.details, found.disabled = click, p.disabled
		end
		if type(click) == "string" and string.sub(click, 1, 3) == "wi=" then found.count += 1 end
		for _, c in node.c or {} do details_of(c, found) end
	end
	local function walk(node)
		if type(node) ~= "table" then return end
		local key = node.p and node.p.key
		if type(key) == "string" and string.sub(key, 1, 3) == "wi:" then
			local found = { key = key, count = 0 }
			details_of(node, found)
			table.insert(out, found)
		end
		for _, c in node.c or {} do walk(c) end
	end
	walk((View.render(s, {})))
	return out
end

local function texts(node, acc)
	acc = acc or {}
	if type(node) == "string" then table.insert(acc, node) return acc end
	if type(node) ~= "table" then return acc end
	for key, value in node do
		if key == "c" then
			for _, child in value do texts(child, acc) end
		else
			texts(value, acc)
		end
	end
	return acc
end

-- Clicks an action string the way Tern does: `name=value` splits at the first `=`.
local function click(s, action: string)
	local name, value = string.match(action, "^([^=]+)=(.*)$")
	Store.dispatch(s, nil, name or action, if name then value else nil)
end

-- Rendered rows: unique keys that carry the full identity, and one complete Details action per record.
local s = new_store(Dev)
local rows = rendered_rows(s)
check(#rows == 4, "every cached work item renders one row")
local seen, unique = {}, true
for _, row in rows do
	if seen[row.key] then unique = false end
	seen[row.key] = true
end
check(unique, "Same ID in different namespaces renders unique row keys")
local actions_seen, distinct = {}, true
for i = 1, 3 do
	local action = rows[i].details
	check(type(action) == "string" and action ~= "wi=7" and rows[i].count == 1, "Row " .. i .. " renders exactly one non-ID-only Details action")
	if actions_seen[action] then distinct = false end
	actions_seen[action] = true
end
check(distinct, "Homonymous rows render distinct Details actions")
check(rows[4].details == nil or rows[4].disabled ~= nil, "A cached row without tenant and project cannot be opened")
check(rows[4].details ~= "wi=8" and rows[4].details ~= "wi", "A row without a namespace never falls back to an ID-only action")

-- Each rendered action reaches the CLI with its own tenant and project, root unchanged, and shows its own record.
local expected = {
	{ tenant = TENANT_A, project = SHARED, title = "Alpha record" },
	{ tenant = TENANT_B, project = SHARED, title = "Beta record" },
	{ tenant = TENANT_A, project = ODD, title = "Gamma record" },
}
for i, want in expected do
	local before = #runs
	local s2 = new_store(Dev)
	click(s2, rendered_rows(s2)[i].details)
	local argv = runs[#runs]
	check(#runs == before + 1 and argv[2] == "wi" and argv[3] == "view" and argv[4] == "7" and table.find(argv, "--offline") ~= nil, want.title .. ": opens `wi view 7 --offline`")
	check(flag_value(argv, "--tenant") == want.tenant, want.title .. ": forwards its own --tenant")
	check(flag_value(argv, "--project") == want.project, want.title .. ": forwards its own --project (decoded)")
	check(flag_value(argv, "--root") == "C:/root" and table.find(argv, "--provider") == nil, want.title .. ": keeps the root and invents no provider")
	check(s2.screen == "wi" and s2.wi and s2.wi.data and s2.wi.data.title == want.title and s2.wi.data.tenant == want.tenant and s2.wi.data.project == want.project, want.title .. ": the opened record is the one that was requested")
	check(table.find(texts(View.render(s2, {})), want.title) ~= nil, want.title .. ": the detail screen renders that record")
end

-- Store -> port input: id, tenant and project are separate fields; the port argv names the namespace.
do
	local calls = {}
	local fake = setmetatable({}, { __index = function(_, op)
		return function(input, done) table.insert(calls, { op = op, input = input, done = done }) end
	end })
	local s3 = new_store(fake)
	local rows3 = rendered_rows(s3)
	click(s3, rows3[1].details)
	click(s3, rows3[2].details)
	local first, second = calls[1], calls[2]
	check(first and first.op == "work_item" and tostring(first.input.id) == "7" and first.input.tenant == TENANT_A and first.input.project == SHARED and first.input.root == "C:/root", "Store passes id, tenant, project and root to the port")
	check(second and second.input.tenant == TENANT_B and second.input.project == SHARED, "A second selection passes its own namespace")
	-- The first answer arrives late: it must not replace the record now on screen.
	first.done({ ok = true, value = CACHE[TENANT_A .. "|" .. SHARED .. "|7"] }, nil)
	check(s3.wi.loading == true and s3.wi.data == nil, "A late answer for a replaced selection is dropped")
	second.done({ ok = true, value = CACHE[TENANT_B .. "|" .. SHARED .. "|7"] }, nil)
	check(s3.wi.data and s3.wi.data.title == "Beta record", "The current selection's answer is shown")

	-- Malformed internal selections do nothing: no screen change, no port call, no provider lookup.
	local s4 = new_store(fake)
	local before = #calls
	for _, bad in { "7", "wi", "a|b", "|p|7", "t||7", "t|p|x", "t|p|0", "t|p|7|extra", "t|p|", TENANT_A .. "|" .. SHARED .. "|-7" } do
		Store.dispatch(s4, nil, "wi", bad)
	end
	Store.dispatch(s4, nil, "wi", nil)
	check(#calls == before and s4.screen == "wis" and s4.wi == nil, "Malformed work-item selections are ignored")
end

Shim.tern.process.run = nil
Shim.env_override.DEV_TERN_BIN = nil
if failures > 0 then error(failures .. " work-item identity checks failed") end
print("work item identity tests passed")
