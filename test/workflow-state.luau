--!nonstrict
-- Focused state contracts for worksets, reviewed creation and live work-item selection.
local process = require("@lune/process")
local Shim = require("./shim")
local root = string.gsub(process.cwd, "\\", "/")
root = string.gsub(root, "/$", "")
local Store = Shim.load(root .. "/store.luau")
Shim.tern.timer = function() return { cancel = function() end } end

local function fake()
	local d = { calls = {} }
	setmetatable(d, { __index = function(_, op)
		return function(input, done)
			table.insert(d.calls, { op = op, input = input, done = done })
		end
	end })
	return d
end
local function calls(d, op)
	local out = {}
	for _, c in d.calls do if c.op == op then table.insert(out, c) end end
	return out
end
local function last(d, op)
	local list = calls(d, op)
	return list[#list]
end
local function answer(c, value)
	c.done({ ok = true, value = value }, nil)
end
local function reject(c, code, details)
	c.done({ ok = false, error = { code = code, message = code, details = details or {} } }, nil)
end
local function new_store(d, path)
	local s = Store.new({ surface = "sidebar", dev = d, redraw = function() end, effect = function() end })
	s.active_root = path or "C:/root"
	return s
end

-- A list response should not erase earlier successful data when another source read fails.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.load_sources(s, nil)
	answer(last(d, "worksets"), { { name = "safe" } })
	reject(last(d, "labels"), "OFFLINE")
	answer(last(d, "catalog"), { { name = "Repo", url = "https://example.test/Repo", disabled = false } })
	assert(s.worksets[1].name == "safe" and s.labels_error.code == "OFFLINE")
	assert(s.catalog[1].url == "https://example.test/Repo")
end

-- Same-name normalized cached records remain distinct by full URL identity.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.load_sources(s, nil)
	answer(last(d, "catalog"), {
		{ name = "Same", url = "https://one.test/Same", default_branch = "main", project = "one" },
		{ name = "Same", url = "ssh://two.test/Same", organization = "two" },
	})
	assert(#s.catalog == 2 and s.catalog[1].url ~= s.catalog[2].url)
end

-- A delayed detail answer from another root or a cancelled dialog cannot replace the current modal's state.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "workset.edit", "draft")
	local old = last(d, "workset")
	Store.dispatch(s, nil, "root", "C:/other")
	answer(old, { members = { { source = "https://repo.test/a" } } })
	assert(s.workset_detail == nil or s.workset_detail.data == nil)
end

do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "workset.edit", "draft")
	local old = last(d, "workset")
	Store.dispatch(s, nil, "modal.close")
	Store.dispatch(s, nil, "workset.new")
	answer(old, { members = {} })
	assert(s.modal == "workset" and (s.workset_detail == nil or s.workset_detail.data == nil))
end

do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "create")
	Store.preview_workspace(s, nil, { source = "url", url = "https://repo.test/pull/3" })
	local old = last(d, "create_plan")
	Store.dispatch(s, nil, "modal.close")
	Store.dispatch(s, nil, "create")
	answer(old, { name = "late", path = "C:/root/ws/late", exists = false, mounts = {} })
	assert(s.modal == "create" and s.creation == nil)
end

-- Unreviewed legacy forms cannot reach the new create mutation path.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "create")
	assert(Store.create_workspace(s, nil, { source = "empty", name = "unreviewed" }) == false)
	assert(#calls(d, "create") == 0)
end

-- Preview callbacks belong to their initiating root/dialog. Commit uses the immutable reviewed plan.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "create")
	local form = { source = "repositories", name = "checked", repositories = { { source = "https://repo.test/a", branch = "main" } } }
	Store.preview_workspace(s, nil, form)
	local preview = last(d, "create_plan")
	answer(preview, { name = "checked", description = "Resolved recipe description", path = "C:/root/ws/checked", exists = false, mounts = { { source = "https://repo.test/a", branch = "main" } } })
	assert(s.creation and s.creation.data.name == "checked")
	form.repositories[1].source = "https://repo.test/changed"
	Store.dispatch(s, nil, "create.commit")
	local commit = last(d, "create")
	assert(commit and commit.input.name == "checked" and commit.input.repositories[1].source == "https://repo.test/a")
	assert(commit.input.desc == "Resolved recipe description", "Creation retains the description from the reviewed backend proposal")
end

-- A failed workset save retains both the dialog and draft; the next live choice retains provider selection.
do
	local d, s = fake(), nil
	s = new_store(d)
	Store.dispatch(s, nil, "workset.new")
	s.workset_draft = { name = "keep", definition = { members = {} } }
	Store.save_workset(s, nil, { name = "keep", definition = { members = {} } })
	reject(last(d, "save_workset"), "INVALID")
	assert(s.modal == "workset" and s.workset_draft.name == "keep")
end

do
	local d, s = fake(), nil
	s = new_store(d)
	Store.load_wis(s, nil, true)
	reject(last(d, "work_items"), "INTERACTION_REQUIRED", { field = "provider", choices = { "azure" } })
	assert(s.modal == "live" and s.live_selection.field == "provider")
	Store.dispatch(s, nil, "live.select", "azure")
	reject(last(d, "work_items"), "INTERACTION_REQUIRED", { field = "project", choices = { "alpha" } })
	assert(s.modal == "live" and s.live_selection.field == "project")
	Store.dispatch(s, nil, "live.select", "alpha")
	local input = last(d, "work_items").input
	assert(input.provider == "azure" and input.project == "alpha")
end

print("workflow state tests passed")
