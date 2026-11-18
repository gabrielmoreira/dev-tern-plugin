--!nonstrict
-- Native dialog presentation and unsaved editing state. Data reads and writes belong to Store.
local Store = require("./store")
local View = require("./view")
local ui = tern.ui
local Forms = {}
Forms.keys = { "f_name", "f_desc", "f_url", "f_repo", "f_branch", "f_path", "f_reason", "f_setup", "f_member_setup", "f_label", "f_pick", "f_pr_repo", "f_pr_provider", "f_pr_project", "f_pr_ws", "f_pr_label" }

local function trim(value)
	return string.match(tostring(value or ""), "^%s*(.-)%s*$")
end
local function optional(value)
	local text = trim(value)
	return if text == "" then nil else text
end
function Forms.set_field(state, key, text)
	local value = tostring(text or "")
	state.fields[key] = { text = value, cursor = #value }
end
local function field(state, key)
	return state.fields[key].text
end
local function label(text)
	return ui.text(ui.span(text, "muted strong"))
end
local function wrap(kids)
	return View.with(ui.col(kids), { key = "form", role = View.role("form") })
end
local function copy_members(members)
	local result = {}
	for _, member in members or {} do table.insert(result, table.clone(member)) end
	return result
end
function Forms.reset(state)
	for _, key in Forms.keys do Forms.set_field(state, key, "") end
	state.form = { source = "empty", labels = {}, repositories = {}, members = {}, readonly = false, step = "edit" }
	state.picker = nil
end
function Forms.sync(state)
	local s = state.store
	if s.modal and state.form_seq ~= s.modal_seq then
		Forms.reset(state)
		state.form_seq = s.modal_seq
		if s.modal == "create" and s.modal_workset then
			state.form.source, state.form.workset = "workset", s.modal_workset
			Forms.set_field(state, "f_name", s.modal_workset)
			for _, w in s.worksets or {} do
				if w.name == s.modal_workset then Forms.set_field(state, "f_desc", w.description) end
			end
		elseif s.modal == "prsfilters" then
			state.form.source = "prsfilters"
		end
	elseif not s.modal then
		state.picker = nil
	end
	local detail = s.workset_detail
	if s.modal == "workset" and detail and detail.data and not state.form.loaded then
		local d = detail.data
		state.form.loaded, state.form.original_name = true, detail.name or d.name
		state.form.members = copy_members(d.members)
		Forms.set_field(state, "f_name", d.name or detail.name)
		Forms.set_field(state, "f_desc", d.description)
		Forms.set_field(state, "f_setup", d.setup)
	end
	if s.modal == "create" and s.creation and state.form.plan_seen ~= s.creation then
		state.form.plan_seen = s.creation
		if trim(field(state, "f_name")) == "" then Forms.set_field(state, "f_name", s.creation.data.name) end
		if trim(field(state, "f_desc")) == "" then Forms.set_field(state, "f_desc", s.creation.data.description) end
	end
	if s.modal == "prsfilters" and s.pr_query and not state.form.pr_query_loaded then
		state.form.pr_query_loaded = true
		local q = s.pr_query
		Forms.set_field(state, "f_pr_repo", q.repo)
		Forms.set_field(state, "f_pr_provider", q.provider)
		Forms.set_field(state, "f_pr_project", q.project)
		Forms.set_field(state, "f_pr_ws", q.ws)
		Forms.set_field(state, "f_pr_label", q.label)
		state.form.pr_scope, state.form.pr_status = q.scope or "mine", q.status or "open"
	end
end
function Forms.values(state)
	local repositories = copy_members(state.form.repositories)
	for _, r in repositories do r.manual = nil end
	return {
		source = state.form.source, workset = state.form.workset, labels = table.clone(state.form.labels),
		repositories = repositories, readonly = state.form.readonly,
		name = optional(field(state, "f_name")), desc = optional(field(state, "f_desc")),
		url = trim(field(state, "f_url")), repo = trim(field(state, "f_repo")),
		branch = optional(field(state, "f_branch")), path = optional(field(state, "f_path")), setup = optional(field(state, "f_setup")),
	}
end
local function definition(state)
	return { description = optional(field(state, "f_desc")), setup = optional(field(state, "f_setup")), members = copy_members(state.form.members) }
end
local function selected(set, value)
	return table.find(set, value) ~= nil
end
local function filtered(state)
	local p = state.picker
	local result, words = {}, {}
	for word in string.gmatch(string.lower(field(state, "f_pick")), "%S+") do table.insert(words, word) end
	for i, item in p.items do
		local hay = string.lower(item.label .. " " .. (item.detail or ""))
		local matches = true
		for _, word in words do if not string.find(hay, word, 1, true) then matches = false break end end
		if matches then table.insert(result, i) end
	end
	return result
end
local function close_picker(state)
	local target = state.picker and state.picker.return_field
	state.picker = nil
	state.focus_field = target
	if target then state.cx:frame({ { "focus", "layer.dialog.form." .. target } }) end
end
local function open_picker(state, kind)
	local s, items, values = state.store, {}, {}
	local repositories = kind == "create.repositories" or kind == "add.repo" or kind == "member.source"
	if repositories then
		local seen = {}
		for _, r in s.catalog or {} do
			if not seen[r.url] then
				seen[r.url] = true
				table.insert(items, { value = r.url, label = tostring(r.name or r.url), detail = table.concat({ tostring(r.organization or ""), tostring(r.project or ""), tostring(r.url) }, " · "), record = r })
			end
		end
	elseif kind == "create.workset" then
		for _, w in s.worksets or {} do table.insert(items, { value = w.name, label = w.name, detail = w.description or "", record = w }) end
	elseif kind == "create.labels" or kind == "member.label" then
		for _, l in s.labels or {} do
			local name = tostring(l.name or l.label)
			table.insert(items, { value = name, label = name, detail = tostring(l.count or l.repositoryCount or "") .. " repositories" })
		end
	elseif kind == "live" and s.live_selection then
		for _, c in s.live_selection.choices or {} do
			local value = if type(c) == "table" then c.value else c
			table.insert(items, { value = tostring(value), label = if type(c) == "table" then tostring(c.label or value) else tostring(c), detail = "" })
		end
	end
	if kind == "create.repositories" then
		local seen = {}
		for _, r in state.form.repositories do
			if not r.manual and not seen[r.source] then seen[r.source] = true table.insert(values, r.source) end
		end
	elseif kind == "create.labels" then values = table.clone(state.form.labels) end
	state.picker = { kind = kind, items = items, values = values, multi = kind == "create.repositories" or kind == "create.labels", cursor = 1, limit = 40, return_field = state.focus_field }
	Forms.set_field(state, "f_pick", "")
	state.focus_field = "f_pick"
	state.cx:frame({ { "focus", "layer.dialog.form.f_pick" } })
end
local function invalidate(state)
	if state.store.modal == "create" then Store.invalidate_creation(state.store) end
	state.form.step = "edit"
end
function Forms.changed(state, key)
	if key == "f_pick" and state.picker then
		state.picker.cursor, state.picker.limit = 1, 40
	elseif state.store.modal then invalidate(state) end
end
local function pick(state, index, cx)
	local p = state.picker
	local item = p and p.items[tonumber(index) or 0]
	if not item then return end
	if p.multi then
		local at = table.find(p.values, item.value)
		if at then table.remove(p.values, at) else table.insert(p.values, item.value) end
		if p.kind == "create.repositories" then
			local previous, out = {}, {}
			for _, r in state.form.repositories do
				previous[r.source] = previous[r.source] or { picked = {}, manual = {} }
				table.insert(if r.manual then previous[r.source].manual else previous[r.source].picked, r)
			end
			for _, value in p.values do
				local old = previous[value]
				if old and #old.picked > 0 then
					for _, r in old.picked do table.insert(out, table.clone(r)) end
				else
					for _, candidate in p.items do
						if candidate.value == value then table.insert(out, { source = value, branch = candidate.record.default_branch }) break end
					end
				end
			end
			for _, group in previous do
				for _, r in group.manual do table.insert(out, table.clone(r)) end
			end
			state.form.repositories = out
		else state.form.labels = table.clone(p.values) end
		invalidate(state)
	else
		if p.kind == "create.workset" then
			state.form.workset = item.value
			Forms.set_field(state, "f_name", item.value)
			Forms.set_field(state, "f_desc", item.record.description)
		elseif p.kind == "add.repo" or p.kind == "member.source" then
			Forms.set_field(state, "f_repo", item.value)
			Forms.set_field(state, "f_branch", item.record.default_branch)
		elseif p.kind == "member.label" then Forms.set_field(state, "f_label", item.value)
		elseif p.kind == "live" then
			close_picker(state)
			Store.dispatch(state.store, cx, "live.select", item.value)
			return
		end
		invalidate(state)
		close_picker(state)
	end
end
function Forms.key(state, key, cx)
	if not state.picker then return false end
	if key.name == "escape" or key.name == "esc" then close_picker(state) return true end
	local matches = filtered(state)
	if key.name == "up" or key.name == "down" then
		state.picker.cursor = math.clamp(state.picker.cursor + (if key.name == "down" then 1 else -1), 1, math.max(1, #matches))
		state.picker.limit = math.max(state.picker.limit, state.picker.cursor)
		return true
	elseif key.name == "enter" then
		local index = matches[state.picker.cursor]
		if index then pick(state, index, cx) end
		return true
	end
	return false
end
local function picker_view(state, input)
	local p, kids = state.picker, {}
	local matches = filtered(state)
	table.insert(kids, label(if p.kind == "live" then "Choose " .. tostring(state.store.live_selection.field) else "Choose " .. (if string.find(p.kind, "labels", 1, true) or p.kind == "member.label" then "labels" elseif p.kind == "create.workset" then "a workset" else "repositories")))
	table.insert(kids, input(state, "f_pick", "Search names, projects or URLs…", "Search choices"))
	table.insert(kids, View.hint(tostring(#matches) .. " matches" .. (if p.multi then " · " .. #p.values .. " selected" else "") .. " · ↑ ↓ move · Enter selects · Esc returns"))
	if #matches == 0 then table.insert(kids, View.hint("No matching cached choices. Return to enter a repository URL or path manually.")) end
	for position, index in matches do
		if position > p.limit then break end
		local item = p.items[index]
		local on = selected(p.values, item.value)
		table.insert(kids, View.with(ui.col({
			View.button((if p.multi then (if on then "✓ " else "+ ") else "") .. item.label, "select.item=" .. index, { on = on, variant = if position == p.cursor then "primary" else "quiet", size = "md", title = item.detail }),
			View.hint(item.detail),
		}), { role = View.role("selection-row") }))
	end
	if #matches > p.limit then table.insert(kids, View.button("Show more choices", "select.more", { variant = "quiet" })) end
	return kids
end
local function member_rows(members, editing)
	local rows = {}
	for i, m in members do
		local detail = (if m.ref then " @ " .. m.ref else "") .. (if m.path then " → " .. m.path else "")
		local setup = if m.setup == false then "Setup skipped" elseif m.setup then "Setup: " .. m.setup else "Inherits workset setup"
		local kids = { ui.text(ui.span((if m.label then "Label: " .. m.label else tostring(m.source)) .. detail, "strong")) }
		if m.reason then table.insert(kids, View.hint(m.reason)) end
		table.insert(kids, View.hint(setup))
		if editing then table.insert(kids, ui.row({ View.button("Edit", "member.edit=" .. i, { variant = "quiet" }), View.button("Remove", "member.remove=" .. i, { variant = "quiet" }) })) end
		table.insert(rows, View.with(ui.col(kids), { role = View.role("selection-row") }))
	end
	return rows
end
local function append(out, items)
	for _, item in items do table.insert(out, item) end
end
local function failure(state, kids)
	local f = state.store.failure
	if f and ({ create = true, create_plan = true, save_workset = true, add = true })[f.op] then table.insert(kids, View.error_card(f.label, f.error, "dialog-error")) end
end
function Forms.validate(state)
	local s, f, v = state.store, state.form, Forms.values(state)
	if state.picker then return nil end
	if s.modal == "live" then return "Choose a provider or project" end
	if s.modal == "prsfilters" then
		if s.busy and s.busy.pull_requests then return "Reading pull requests…" end
		if optional(field(state, "f_pr_label")) and (optional(field(state, "f_pr_repo")) or optional(field(state, "f_pr_ws"))) then return "Label filters cannot be combined with repository or workspace filters" end
		return nil
	end
	if s.modal == "workset" then
		if s.workset_detail and s.workset_detail.loading then return "Reading workset…" end
		if s.workset_detail and s.workset_detail.error and not f.loaded then return "Read the workset before editing" end
		if f.member_kind then
			if f.member_kind == "label" and trim(field(state, "f_label")) == "" then return "Enter or choose a label" end
			if f.member_kind == "repository" and v.repo == "" then return "Enter or choose a repository" end
			if f.member_setup == "custom" and trim(field(state, "f_member_setup")) == "" then return "Enter the setup command" end
		elseif not v.name then return "Enter a workset name"
		elseif #f.members == 0 then return "Add at least one repository or label" end
		if s.busy.save_workset then return "Saving workset…" end
	elseif s.modal == "create" then
		if f.repository_edit then
			if trim(field(state, "f_repo")) == "" then return "Enter a repository URL or path" end
			if f.member_setup == "custom" and trim(field(state, "f_member_setup")) == "" then return "Enter the setup command" end
			return nil
		end
		if s.busy.create or s.busy.create_plan then return "Resolving or creating workspace…" end
		if s.creation then
			if s.creation.data.exists then return "Choose a different name or open the existing workspace" end
			return nil
		end
		if v.source == "url" and v.url == "" then return "Enter a repository URL, local path or pull request URL" end
		if v.source == "repositories" and #v.repositories == 0 then return "Choose repositories or add a URL or path" end
		if v.source == "workset" and not v.workset then return "Choose a workset" end
		if v.source == "label" and #v.labels == 0 then return "Choose labels" end
		if not v.name and v.source ~= "url" and not (v.source == "repositories" and #v.repositories == 1) then return "Enter a workspace name" end
		if v.name and string.find(v.name, "[/\\%s]") then return "Names cannot hold spaces or path separators" end
	elseif s.modal == "add" then
		if v.repo == "" then return "Enter or choose a repository" end
		if s.busy.add then return "Adding repository…" end
	end
	return nil
end
function Forms.submit(state, cx)
	if state.picker then close_picker(state) return end
	if Forms.validate(state) then return end
	local s, f = state.store, state.form
	if s.modal == "prsfilters" then
		local query = { scope = f.pr_scope or "mine", status = f.pr_status or "open" }
		for key, field_key in { repo = "f_pr_repo", provider = "f_pr_provider", project = "f_pr_project", ws = "f_pr_ws", label = "f_pr_label" } do query[key] = optional(field(state, field_key)) end
		Store.dispatch(s, cx, "prs.query", query)
	elseif s.modal == "create" and f.repository_edit then
		local original = f.repositories[f.repository_index]
		local r = {
			source = trim(field(state, "f_repo")), branch = optional(field(state, "f_branch")),
			path = optional(field(state, "f_path")), reason = optional(field(state, "f_reason")),
			setup = if f.member_setup == "skip" then false elseif f.member_setup == "custom" then optional(field(state, "f_member_setup")) else nil,
			manual = if f.repository_manual then true else nil,
		}
		if original then f.repositories[f.repository_index] = r else table.insert(f.repositories, r) end
		f.repository_edit, f.repository_new, f.repository_index, f.member_setup, f.repository_manual = nil, nil, nil, nil, nil
		invalidate(state)
	elseif s.modal == "create" then
		if s.creation then Store.commit_workspace(s, cx) else Store.preview_workspace(s, cx, Forms.values(state)) end
	elseif s.modal == "add" then
		Store.add_repo(s, cx, s.modal_ws or s.selected, Forms.values(state))
	elseif s.modal == "workset" and f.member_kind then
		local m = if f.member_kind == "label" then { label = trim(field(state, "f_label")), reason = optional(field(state, "f_reason")) }
			else { source = trim(field(state, "f_repo")), ref = optional(field(state, "f_branch")), path = optional(field(state, "f_path")), reason = optional(field(state, "f_reason")), setup = if f.member_setup == "skip" then false elseif f.member_setup == "custom" then optional(field(state, "f_member_setup")) else nil }
		if f.member_index then f.members[f.member_index] = m else table.insert(f.members, m) end
		f.member_kind, f.member_index, f.step = nil, nil, "edit"
	elseif s.modal == "workset" then
		if f.step == "review" then Store.save_workset(s, cx, { name = trim(field(state, "f_name")), original_name = f.original_name, definition = definition(state) })
		else f.step = "review" end
	end
end
local function member_form(state, input)
	local f, kids = state.form, {}
	if f.member_kind == "label" then
		append(kids, { label("Label"), input(state, "f_label", "team:api", "Workset label"), View.button("Choose label…", "select.open=member.label", { variant = "quiet" }) })
	else
		append(kids, { label("Repository"), input(state, "f_repo", "Repository URL, path or known name", "Repository"), View.button("Choose repository…", "select.open=member.source", { variant = "quiet" }), label("Branch, tag or revision"), input(state, "f_branch", "Remote default", "Repository revision"), label("Mount path"), input(state, "f_path", "Derived from the repository", "Mount path") })
	end
	append(kids, { label("Reason (optional)"), input(state, "f_reason", "Why this task needs it", "Member reason") })
	if f.member_kind ~= "label" then
		table.insert(kids, label("Setup"))
		local modes = {}
		for _, mode in { { "Inherit", "inherit" }, { "Custom", "custom" }, { "Skip", "skip" } } do table.insert(modes, View.button(mode[1], "member.setup=" .. mode[2], { on = f.member_setup == mode[2], variant = "quiet" })) end
		table.insert(kids, View.with(ui.row(modes), { role = View.role("choices") }))
		if f.member_setup == "custom" then table.insert(kids, input(state, "f_member_setup", "Command run in this repository", "Member setup command")) end
	end
	table.insert(kids, View.hint("Apply changes only updates this draft. Save the workset after reviewing it."))
	return kids
end
local function workset_form(state, input, editor)
	local s, f = state.store, state.form
	if s.workset_detail and s.workset_detail.loading and not f.loaded then return { ui.progress(nil, "Reading workset…") } end
	if s.workset_detail and s.workset_detail.error and not f.loaded then return { View.error_card("Could not read workset", s.workset_detail.error, "workset-read-error"), View.button("Try again", "workset.retry", { variant = "quiet" }) } end
	if f.member_kind then return member_form(state, input) end
	local kids = { View.hint("A workset is a saved workspace recipe. Existing workspaces are not changed.") }
	if f.step == "review" then
		append(kids, { label(trim(field(state, "f_name"))), ui.text(field(state, "f_desc")), View.hint(if optional(field(state, "f_setup")) then "Default setup: " .. field(state, "f_setup") else "No default setup command") })
		append(kids, member_rows(f.members, false))
	else
		append(kids, { label("Name"), input(state, "f_name", "incident", "Workset name"), label("Description"), editor(state, "f_desc", "What this recipe is for"), label("Default setup command (optional)"), input(state, "f_setup", "Run after creating each repository", "Default setup command"), View.hint("Setup runs only under the CLI's trust policy. Saving a recipe does not run it."), label("Repositories and labels") })
		append(kids, member_rows(f.members, true))
		if #f.members == 0 then table.insert(kids, View.hint("Add the repositories or labels this recipe needs.")) end
		table.insert(kids, ui.row({ View.button("Add repository", "member.new=repository", { icon = "plus" }), View.button("Add label", "member.new=label", { variant = "quiet" }) }))
	end
	return kids
end
local function create_form(state, input, editor)
	local s, f = state.store, state.form
	local plan = s.creation and s.creation.data
	if f.repository_edit then
		return {
			label(if f.repository_new then "Another repository revision" else "Edit repository"),
			label("Repository URL or path"), input(state, "f_repo", "URL or local path", "Repository"),
			label("Branch, tag or revision"), input(state, "f_branch", "Remote default branch", "Repository revision"),
			label("Mount path"), input(state, "f_path", "Derived from the repository", "Mount path"),
			label("Reason (optional)"), input(state, "f_reason", "Why this repository is needed", "Repository reason"),
			label("Setup"),
			View.with(ui.row({ View.button("Inherit", "repository.setup=inherit", { on = f.member_setup == "inherit", variant = "quiet" }), View.button("Custom", "repository.setup=custom", { on = f.member_setup == "custom", variant = "quiet" }), View.button("Skip", "repository.setup=skip", { on = f.member_setup == "skip", variant = "quiet" }) }), { role = View.role("choices") }),
			if f.member_setup == "custom" then input(state, "f_member_setup", "Command run in this repository", "Repository setup command") else View.hint(if f.member_setup == "skip" then "Setup will be skipped for this mount." else "Use the workspace setup command."),
			View.hint("Apply changes only updates this draft.")
		}
	end
	if plan then
		local kids = { label("Review workspace"), ui.text(ui.span(tostring(plan.name), "strong")), ui.text(tostring(plan.description or "")), View.hint("Destination: " .. tostring(plan.path or "")) }
		if plan.exists then table.insert(kids, View.hint("This workspace already exists. Go back to choose another name, or open it without changing it.")) table.insert(kids, View.button("Open existing workspace", "ws=" .. tostring(plan.name), { variant = "quiet" })) end
		if #(plan.mounts or {}) == 0 then table.insert(kids, View.hint("Empty workspace. You can add repositories later.")) end
		for i, m in plan.mounts or {} do
			table.insert(kids, View.with(ui.col({ ui.text(ui.span(tostring(m.path) .. " · " .. tostring(m.branch or "remote default branch"), "strong")), View.hint(tostring(m.source)), View.hint(if m.setup then "Setup: " .. tostring(m.setup) else "No setup command"), View.hint(tostring(m.reason or "")), View.button("Edit", "repository.edit=" .. i, { variant = "quiet" }) }), { role = View.role("selection-row") }))
		end
		table.insert(kids, View.button("Customize repositories", "repository.customize", { variant = "quiet" }))
		table.insert(kids, View.hint("Create uses these reviewed repositories, branches and paths. Setup remains subject to trust; no additional consent is granted."))
		return kids
	end
	local choices = {}
	for _, mode in { { "Empty", "empty" }, { "Repositories", "repositories" }, { "Workset", "workset" }, { "Labels", "label" }, { "URL or PR", "url" } } do table.insert(choices, View.button(mode[1], "src=" .. mode[2], { on = f.source == mode[2], variant = if f.source == mode[2] then "primary" else "quiet" })) end
	local kids = { label("Start from"), View.with(ui.row(choices), { role = View.role("choices") }) }
	if f.source == "repositories" then
		table.insert(kids, View.button("Choose repositories…", "select.open=create.repositories", { variant = "quiet" }))
		for i, r in f.repositories do table.insert(kids, ui.row({ View.hint(r.source .. (if r.branch then " @ " .. r.branch else "") .. (if r.path then " → " .. r.path else "")), View.button("Edit", "repository.edit=" .. i, { variant = "quiet" }), View.button("Another revision", "repository.duplicate=" .. i, { variant = "quiet" }), View.button("Remove", "repository.remove=" .. i, { variant = "quiet" }) })) end
	elseif f.source == "workset" then
		append(kids, { label("Workset"), View.button(f.workset or "Choose a workset…", "select.open=create.workset", { variant = "quiet" }) })
	elseif f.source == "label" then
		append(kids, { label("Labels"), View.button(if #f.labels > 0 then table.concat(f.labels, ", ") else "Choose labels…", "select.open=create.labels", { variant = "quiet" }) })
	elseif f.source == "url" then append(kids, { label("Repository URL, local path or pull request URL"), input(state, "f_url", "https://… or a local path", "Repository or PR URL"), View.hint("Review resolves the repository or PR and proposes a name and description.") }) end
	append(kids, { label("Workspace name" .. (if f.source == "url" or (f.source == "repositories" and #f.repositories == 1) then " (optional proposal)" else "")), input(state, "f_name", "feature-x", "Workspace name"), label("Description (optional)"), editor(state, "f_desc", "What this task is about"), label("Setup command (optional)"), input(state, "f_setup", "Use the recipe defaults", "Workspace setup command") })
	local name = optional(field(state, "f_name"))
	if name and Store.workspace(s, name) then table.insert(kids, ui.row({ View.hint("A workspace named " .. name .. " already exists."), View.button("Open it", "ws=" .. name, { variant = "quiet" }) })) end
	return kids
end
function Forms.render(state, input, editor)
	Forms.sync(state)
	local s, kids = state.store, {}
	if state.picker then return wrap(picker_view(state, input)) end
	if s.modal == "workset" then kids = workset_form(state, input, editor)
	elseif s.modal == "create" then kids = create_form(state, input, editor)
	elseif s.modal == "prsfilters" then
		kids = {
			label("Scope"),
			View.with(ui.row({ View.button("Mine", "prs.scope=mine", { on = state.form.pr_scope == "mine", variant = "quiet" }), View.button("All", "prs.scope=all", { on = state.form.pr_scope == "all", variant = "quiet" }) }), { role = View.role("choices") }),
			label("Status"),
			View.with(ui.row({ View.button("Open", "prs.status=open", { on = state.form.pr_status == "open", variant = "quiet" }), View.button("Completed", "prs.status=completed", { on = state.form.pr_status == "completed", variant = "quiet" }), View.button("Abandoned", "prs.status=abandoned", { on = state.form.pr_status == "abandoned", variant = "quiet" }), View.button("Closed", "prs.status=closed", { on = state.form.pr_status == "closed", variant = "quiet" }), View.button("All", "prs.status=all", { on = state.form.pr_status == "all", variant = "quiet" }) }), { role = View.role("choices") }),
			label("Repository (optional)"), input(state, "f_pr_repo", "Repository ID", "Repository ID"),
			label("Provider (optional)"), input(state, "f_pr_provider", "Provider ID", "Provider ID"),
			label("Project (optional)"), input(state, "f_pr_project", "Project ID", "Project ID"),
			label("Workspace (optional)"), input(state, "f_pr_ws", "Workspace name", "Workspace"),
			label("Label (optional)"), input(state, "f_pr_label", "Label name", "Label")
		}
		local problem = Forms.validate(state)
		if problem then table.insert(kids, View.hint(problem)) end
	elseif s.modal == "live" then
		kids = { View.hint("Choose the " .. tostring(s.live_selection and s.live_selection.field or "connection") .. " for this fetch. Your provider configuration stays unchanged."), View.button("Choose…", "select.open=live", { variant = "primary" }) }
	else
		kids = { label("Repository"), input(state, "f_repo", "URL, local path, or a name dev knows", "Repository"), View.button("Choose repository…", "select.open=add.repo", { variant = "quiet" }), label("Branch (optional)"), input(state, "f_branch", "Remote default branch", "Branch"), label("Mount path (optional)"), input(state, "f_path", "Derived from the repository", "Mount path"), View.button("Read-only mount", "readonly", { on = state.form.readonly, variant = "quiet" }) }
	end
	if not s.creation and (s.modal == "create" or s.modal == "add" or (s.modal == "workset" and state.form.member_kind)) then
		if s.catalog_error then table.insert(kids, View.hint("Cached suggestions could not be read. Manual repository URLs and paths still work."))
		elseif s.catalog and #s.catalog == 0 then table.insert(kids, View.hint("No cached repository suggestions. Enter a URL or path; opening this dialog does not sync providers.")) end
	end
	failure(state, kids)
	return wrap(kids)
end
function Forms.footer(state)
	if state.picker then return { View.button(if state.picker.multi then "Done" else "Back", "select.close", { variant = "primary", size = "md" }) } end
	local s, f = state.store, state.form
	local out = { View.button("Cancel", "modal.close", { variant = "quiet", size = "md" }) }
	if s.creation or f.step == "review" or f.member_kind or f.repository_edit then table.insert(out, View.button("Back", "form.back", { variant = "quiet", size = "md" })) end
	if s.modal ~= "live" then
		local text = if s.modal == "prsfilters" then "Apply" elseif f.repository_edit then "Apply to draft" elseif s.modal == "add" then "Add repository" elseif s.modal == "create" then (if s.creation then "Create workspace" else "Review workspace") elseif f.member_kind then "Apply to draft" elseif f.step == "review" then "Save workset" else "Review workset"
		table.insert(out, View.button(text, "submit", { variant = "primary", size = "md", disabled = Forms.validate(state) }))
	end
	return out
end
function Forms.title(state)
	if state.picker then return "Select " .. (if state.picker.multi then "items" else "an item") end
	local s, f = state.store, state.form
	return if s.modal == "create" and f.repository_edit then (if f.repository_new then "Another revision" else "Edit repository") elseif s.modal == "create" then "New workspace" elseif s.modal == "add" then "Add repository" elseif s.modal == "live" then "Fetch work items" elseif s.modal == "prsfilters" then "Pull request filters" elseif f.member_kind then "Workset member" elseif f.original_name then "Edit workset" else "New workset"
end
function Forms.shown(state)
	if state.picker then return { f_pick = true } end
	local s, f = state.store, state.form
	if s.modal == "prsfilters" then return { f_pr_repo = true, f_pr_provider = true, f_pr_project = true, f_pr_ws = true, f_pr_label = true } end
	if s.modal == "create" then
		if f.repository_edit then return { f_repo = true, f_branch = true, f_path = true, f_reason = true, f_member_setup = f.member_setup == "custom" } end
		if s.creation then return {} end
		return { f_name = true, f_desc = true, f_setup = true, f_url = f.source == "url", f_repo = f.source == "repositories" }
	elseif s.modal == "add" then return { f_repo = true, f_branch = true, f_path = true }
	elseif s.modal == "workset" then
		if f.member_kind then return { f_repo = f.member_kind == "repository", f_label = f.member_kind == "label", f_branch = f.member_kind == "repository", f_path = f.member_kind == "repository", f_reason = true, f_member_setup = f.member_setup == "custom" } end
		if f.step == "review" or (s.workset_detail and (s.workset_detail.loading or (s.workset_detail.error and not f.loaded))) then return {} end
		return { f_name = true, f_desc = true, f_setup = true }
	end
	return {}
end
function Forms.first(state)
	if state.picker then return "f_pick" end
	if state.store.modal == "prsfilters" then return "f_pr_repo" end
	if state.form.repository_edit then return "f_repo" end
	if state.store.modal == "add" or state.form.member_kind == "repository" then return "f_repo" end
	if state.form.member_kind == "label" then return "f_label" end
	if state.store.modal == "create" and state.form.source == "url" then return "f_url" end
	if Forms.shown(state).f_name then return "f_name" end
	return nil
end
function Forms.allows(act)
	return act == "submit" or act == "src" or act == "readonly" or act == "modal.close" or act == "copy" or act == "ws" or string.sub(act, 1, 7) == "select." or string.sub(act, 1, 7) == "member." or string.sub(act, 1, 11) == "repository." or act == "prs.scope" or act == "prs.status" or act == "form.back" or act == "workset.retry"
end
local function copy_plan_mounts(state, plan)
	state.form.repositories = {}
	for _, m in plan.mounts or {} do
		table.insert(state.form.repositories, { source = m.source, branch = m.branch, path = m.path, setup = if m.setup == nil then false else m.setup, reason = m.reason })
	end
	state.form.source = "repositories"
	Forms.set_field(state, "f_name", plan.name)
	Forms.set_field(state, "f_desc", plan.description)
	Store.invalidate_creation(state.store)
	state.form.plan_seen = nil
end
function Forms.action(state, cx, act, value)
	local s, f = state.store, state.form
	if act == "select.open" then open_picker(state, value)
	elseif act == "select.close" then close_picker(state)
	elseif act == "select.item" then pick(state, value, cx)
	elseif act == "select.more" and state.picker then state.picker.limit += 40
	elseif act == "src" and ({ empty = true, repositories = true, workset = true, label = true, url = true })[value] then f.source = value invalidate(state)
	elseif act == "readonly" then f.readonly = not f.readonly
	elseif act == "repository.manual" then
		local source = optional(field(state, "f_repo"))
		if source then table.insert(f.repositories, { source = source, manual = true }) Forms.set_field(state, "f_repo", "") invalidate(state) end
	elseif act == "repository.edit" or act == "repository.duplicate" then
		if s.creation then copy_plan_mounts(state, s.creation.data) end
		local index = tonumber(value)
		local original = index and f.repositories[index]
		if original then
			local draft = table.clone(original)
			f.repository_edit = if act == "repository.edit" then index else "new"
			f.repository_new = act == "repository.duplicate"
			f.repository_index = if f.repository_new then nil else index
			if f.repository_new then
				local base = tostring(original.path or "repo")
				local n, path = 2, base .. "-2"
				while true do
					local used = false
					for _, r in f.repositories do if r.path == path then used = true break end end
					if not used then break end
					n += 1
					path = base .. "-" .. n
				end
				draft.path = path
			end
			f.member_setup, f.repository_manual = if draft.setup == false then "skip" elseif draft.setup then "custom" else "inherit", draft.manual == true
			Forms.set_field(state, "f_repo", draft.source)
			Forms.set_field(state, "f_branch", draft.branch)
			Forms.set_field(state, "f_path", draft.path)
			Forms.set_field(state, "f_reason", draft.reason)
			Forms.set_field(state, "f_member_setup", if type(draft.setup) == "string" then draft.setup else "")
		end
	elseif act == "repository.setup" and (value == "inherit" or value == "custom" or value == "skip") then f.member_setup = value
	elseif act == "repository.customize" and s.creation then
		copy_plan_mounts(state, s.creation.data)
	elseif act == "repository.remove" then
		local index = tonumber(value)
		if index and f.repositories[index] then table.remove(f.repositories, index) invalidate(state) end
	elseif act == "member.new" and (value == "repository" or value == "label") then
		f.member_kind, f.member_index, f.member_setup = value, nil, "inherit"
		for _, key in { "f_repo", "f_branch", "f_path", "f_reason", "f_member_setup", "f_label" } do Forms.set_field(state, key, "") end
	elseif act == "member.edit" then
		local m = f.members[tonumber(value) or 0]
		if m then
			f.member_index, f.member_kind = tonumber(value), if m.label then "label" else "repository"
			f.member_setup = if m.setup == false then "skip" elseif m.setup then "custom" else "inherit"
			for key, text in { f_repo = m.source or "", f_branch = m.ref or "", f_path = m.path or "", f_reason = m.reason or "", f_member_setup = if type(m.setup) == "string" then m.setup else "", f_label = m.label or "" } do Forms.set_field(state, key, text) end
		end
	elseif act == "member.remove" then
		local index = tonumber(value)
		if index and f.members[index] then table.remove(f.members, index) f.step = "edit" end
	elseif act == "member.setup" and (value == "inherit" or value == "custom" or value == "skip") then f.member_setup = value
	elseif s.modal == "prsfilters" and act == "prs.scope" and (value == "mine" or value == "all") then f.pr_scope = value
	elseif s.modal == "prsfilters" and act == "prs.status" and ({ open = true, completed = true, abandoned = true, closed = true, all = true })[value] then f.pr_status = value
	elseif act == "form.back" then
		if s.creation then Store.invalidate_creation(s)
		elseif f.repository_edit then f.repository_edit, f.repository_new, f.repository_index, f.member_setup = nil, nil, nil, nil
		elseif f.member_kind then f.member_kind, f.member_index = nil, nil
		else f.step = "edit" end
	elseif act == "workset.retry" and s.workset_detail then Store.load_workset(s, cx, s.workset_detail.name)
	else return false end
	return true
end
return Forms
