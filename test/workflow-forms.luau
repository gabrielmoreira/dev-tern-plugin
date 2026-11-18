--!nonstrict
-- Exercise the real native dialog, not a second implementation of the forms.
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
local Dev = Shim.load(base .. "/devcli.luau")
local function answer(value) return function(_, done) done({ ok = true, value = value }, nil) end end
Dev.roots = answer({}) Dev.current = answer({ root = "C:/fixture", source = "default" })
Dev.workspaces = answer({}) Dev.mirrors = answer({}) Dev.worksets = answer({}) Dev.labels = answer({})
local one, two = "https://example.invalid/one/api.git", "https://example.invalid/two/api.git"
Dev.catalog = answer({ { name = "api", url = one, project = "one", default_branch = "main" }, { name = "api", url = two, project = "two", default_branch = "trunk" } })
local previews, created, pr_reads, held_pr = {}, nil, {}, nil
Dev.create_plan = function(input, done)
	table.insert(previews, input.form)
	local mounts = {}
	for _, r in input.form.repositories or {} do
		table.insert(mounts, { source = r.source, branch = r.branch, path = r.path or "api", setup = r.setup, reason = r.reason })
	end
	done({ ok = true, value = { name = input.form.name or "api-work", description = input.form.desc or "", path = "C:/fixture/ws/api-work", exists = false, mounts = mounts } }, nil)
end
Dev.create = function(input, done) created = input done({ ok = true, value = { created = true } }, nil) end
Dev.pull_requests = function(input, done)
	table.insert(pr_reads, input)
	if input.live then held_pr = done else done({ ok = true, value = {} }, nil) end
end
Shim.load(base .. "/host.luau")
local panel = Shim.blocks.panel
local cx = { pane = 9811, render = function() end, frame = function() end, open = function() end, copy = function() end, toast = function() end }
Shim.panes = { { pane = cx.pane } }
local state = panel.init(cx, { "create" }, nil)
local function action(act, value) panel.event(state, { ev = "action", act = act, value = value }, cx) return panel.view(state, cx) end
local function edit(key, text)
	local current = state.fields[key].text
	panel.event(state, { ev = "edit", id = "layer.dialog.form." .. key, from = 0, to = #current, len = #current, text = text, cursor = #text }, cx)
end
local function has(node, wanted)
	if type(node) ~= "table" then return false end
	if node.p and node.p.actions and node.p.actions.click == wanted then return true end
	for _, child in node.c or {} do if has(child, wanted) then return true end end
	return false
end
local function find_action(node, wanted)
	if type(node) ~= "table" then return nil end
	if node.p and node.p.actions and node.p.actions.click == wanted then return node end
	for _, child in node.c or {} do
		local found = find_action(child, wanted)
		if found then return found end
	end
	return nil
end
panel.view(state, cx)
action("src", "repositories")
action("select.open", "create.repositories")
action("select.item", "1")
local view = action("select.close")
assert(has(view.layer, "repository.edit=1"), "Selected repository must offer branch/path/setup editing before review")
print("Repository draft editor passed")
action("repository.edit", "1")
edit("f_branch", "feature")
edit("f_path", "api-feature")
edit("f_reason", "Needed for this change")
action("repository.setup", "custom")
edit("f_member_setup", "make setup")
action("submit")
assert(state.form.repositories[1].branch == "feature" and state.form.repositories[1].path == "api-feature", "Applying repository edits updates the draft tuple")
assert(state.form.repositories[1].setup == "make setup" and state.form.repositories[1].reason == "Needed for this change", "Per-mount setup and reason stay in the draft")

action("repository.duplicate", "1")
edit("f_branch", "release")
edit("f_path", "api-release")
action("repository.setup", "skip")
action("submit")
assert(#state.form.repositories == 2 and state.form.repositories[2].source == one and state.form.repositories[2].setup == false, "Another revision keeps the same source and records an explicit setup skip")
assert(state.form.repositories[2].path == "api-release" and state.form.repositories[2].branch == "release", "A second revision has its own branch and mount path")
action("select.open", "create.repositories")
action("select.item", "2")
action("select.item", "2")
action("select.close")
assert(#state.form.repositories == 2 and state.form.repositories[1].source == one and state.form.repositories[2].branch == "release", "Toggling another cached URL preserves all tuples of the selected URL")
edit("f_repo", two)
action("repository.manual")
edit("f_repo", two)
action("repository.manual")
action("repository.edit", "3")
edit("f_path", "api-manual-1")
action("submit")
action("repository.edit", "4")
edit("f_path", "api-manual-2")
action("submit")
action("select.open", "create.repositories")
action("select.item", "2")
action("select.item", "2")
action("select.close")
local manual_count = 0
for _, r in state.form.repositories do if r.manual and r.source == two then manual_count += 1 end end
assert(manual_count == 2, "Manually added identical-source entries remain independent of cached picker toggles")
edit("f_name", "forms-workspace")
edit("f_desc", "Reviewed form fixture")
action("submit")
assert(state.store.creation and #previews == 1 and #previews[1].repositories == 4, "Review resolves every selected and manual tuple without deduplication")
assert(has(panel.view(state, cx).layer, "repository.customize"), "Resolved mounts offer a draft customization path")

local name, description = state.store.creation.data.name, state.store.creation.data.description
action("repository.customize")
assert(state.store.creation == nil and #state.form.repositories == 4, "Customizing resolved mounts copies them to draft and invalidates review")
assert(state.fields.f_name.text == name and state.fields.f_desc.text == description, "Customizing mounts retains reviewed name and description")
action("repository.edit", "1")
edit("f_path", "api-final")
action("submit")
assert(state.form.repositories[1].path == "api-final" and state.store.creation == nil, "Apply changes the copied draft without restoring its frozen review")
action("submit")
assert(state.store.creation and #previews == 2 and previews[2].repositories[1].path == "api-final", "Edited mounts require and appear in a fresh backend review")
action("repository.edit", "1")
assert(state.store.creation == nil and #state.form.repositories == 4, "Editing an individual reviewed mount first copies every frozen mount into the draft")
action("form.back")
action("submit")
assert(state.store.creation and #previews == 3 and previews[3].repositories[1].path == "api-final", "Backing out of an individual reviewed edit still requires a fresh review")
local reviewed_mounts = state.store.creation.data.mounts
action("submit")
assert(created and #created.repositories == #reviewed_mounts and created.repositories[1].path == reviewed_mounts[1].path, "Create commits exactly the freshly reviewed mount list")

action("prs.filters")
local previous_query = table.clone(state.store.pr_query)
local old_reads = #pr_reads
edit("f_pr_repo", "repo-42")
edit("f_pr_label", "needs-review")
local conflict = find_action(panel.view(state, cx).layer, "submit")
assert(conflict and conflict.p.disabled ~= nil, "A label cannot be applied with repository or workspace filters")
edit("f_pr_label", "")
edit("f_pr_provider", "ado")
action("modal.close")
assert(#pr_reads == old_reads and state.store.pr_query.repo == previous_query.repo, "Canceling PR filters leaves the query and cached results untouched")
action("prs.filters")
edit("f_pr_repo", "repo-42")
edit("f_pr_provider", "ado")
edit("f_pr_project", "project-7")
edit("f_pr_ws", "forms-workspace")
action("prs.scope", "all")
action("prs.status", "completed")
assert(#pr_reads == old_reads, "Typing and choosing filters never reads PRs")
action("submit")
local applied = pr_reads[#pr_reads]
assert(applied.scope == "all" and applied.status == "completed" and applied.repo == "repo-42" and applied.provider == "ado" and applied.project == "project-7" and applied.ws == "forms-workspace", "Apply sends the exact typed PR query")
action("prs.live")
assert(state.store.busy.pull_requests and held_pr ~= nil, "Precondition: the live PR read is in flight")
action("prs.filters")
local busy_apply = find_action(panel.view(state, cx).layer, "submit")
assert(busy_apply and busy_apply.p.disabled ~= nil, "PR filter Apply stays disabled while a read is busy")
action("modal.close")
held_pr({ ok = true, value = {} }, cx)
assert(not state.store.busy.pull_requests, "The held PR read settles after the filter dialog is canceled")

action("workset.new")
action("member.new", "repository")
edit("f_repo", one)
edit("f_branch", "topic")
action("submit")
action("member.edit", "1")
edit("f_branch", "discarded")
action("form.back")
assert(state.form.members[1].ref == "topic", "Canceling a workset member edit preserves its existing draft tuple")
print("Repository, workset, and PR workflow forms passed")

-- Canonical reviews omit setup when it is skipped. A copied draft must not re-inherit a prior default.
do
	local Forms = Shim.load(base .. "/forms.luau")
	local Store = Shim.load(base .. "/store.luau")
	local draft = { store = Store.new({ surface = "block", dev = {}, redraw = function() end, effect = function() end }), fields = {}, cx = cx }
	Forms.reset(draft)
	Forms.set_field(draft, "f_setup", "echo previous-default")
	draft.store.modal = "create"
	draft.store.creation = { data = { name = "reviewed", mounts = { { source = one, path = "api" } } } }
	Forms.action(draft, cx, "repository.customize")
	assert(draft.form.repositories[1].setup == false, "A reviewed setup omission stays skipped when copied to an editable draft")
end
