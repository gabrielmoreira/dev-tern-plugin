--!nonstrict
-- Text entry in the panel block's native fields, and secrets in diagnostic text. Run from the plugin root:
--   lune run test/native-input.luau
-- Tern 0.9.15 was observed delivering typed text to a block as `key` events (never `edit`) with a field focused,
-- so the block must edit its fields from keys (typed text, paste, caret, selection) as well as from `edit`
-- events, applying each keystroke once. The host's own functions are exercised through the defined block.
local process = require("@lune/process")
local serde = require("@lune/serde")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
base = string.gsub(base, "/$", "")

local failures = {}
local function check(name: string, ok: boolean, detail: any?)
	if ok then
		print("PASS " .. name)
	else
		table.insert(failures, name)
		print("FAIL " .. name .. (if detail ~= nil then ": " .. tostring(detail) else ""))
	end
end

-- dev itself is out of scope here: every read answers at once with an empty, healthy result.
local Dev = Shim.load(base .. "/devcli.luau")
local function answers(value)
	return function(_, done)
		done({ ok = true, value = value }, nil)
	end
end
Dev.roots = answers({})
Dev.current = answers({ root = "C:/dev-root", source = "default" })
Dev.workspaces = answers({})
Dev.mirrors = answers({})
Dev.status = answers({ mounts = {} })
Dev.worksets = answers({})
Dev.labels = answers({})
Dev.catalog = answers({})

Shim.load(base .. "/host.luau")
Shim.load(base .. "/window.luau")
local panel = Shim.blocks.panel

local next_pane = 800
Shim.panes = {}
local function open(args)
	next_pane += 1
	local cx = {
		pane = next_pane,
		renders = 0,
		frames = {},
		render = function(self)
			self.renders += 1
		end,
		frame = function(self, ops)
			table.insert(self.frames, ops)
		end,
		open = function() end,
		copy = function() end,
		toast = function() end,
	}
	table.insert(Shim.panes, { pane = cx.pane })
	local state = panel.init(cx, args, nil)
	panel.resize(state, 100, 30, cx)
	return state, cx
end

local function find(node, pred)
	if type(node) ~= "table" then
		return nil
	end
	if pred(node) then
		return node
	end
	for _, child in node.c or {} do
		local found = find(child, pred)
		if found then
			return found
		end
	end
	return nil
end

-- The input/editor node the user sees for a field key.
local function shown(state, cx, key: string)
	local view = panel.view(state, cx)
	local function is_field(n)
		return (n.k == "input" or n.k == "editor") and n.p and n.p.key == key
	end
	return find(view.main, is_field) or find(view.dock, is_field) or find(view.layer, is_field)
end

local function press(state, cx, name: string, text: string?, mods)
	local key = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
	for k, v in mods or {} do
		key[k] = v
	end
	return panel.key(state, key, cx)
end

local function type_text(state, cx, text: string)
	for _, cp in utf8.codes(text) do
		local ch = utf8.char(cp)
		press(state, cx, if ch == " " then "space" else ch, ch)
	end
end

local function pasted(state, cx, text: string)
	return panel.key(state, { name = "paste", text = text, ctrl = false, alt = false, shift = false, meta = false }, cx)
end

-- Filter field on the home screen --------------------------------------------------------------------------------
do
	local state, cx = open(nil)
	check("the filter has the keyboard after the panel opens", state.focus_field == "f_filter", state.focus_field)
	type_text(state, cx, "ab")
	check("typed keys fill the focused field", state.fields.f_filter.text == "ab", state.fields.f_filter.text)
	local node = shown(state, cx, "f_filter")
	check("the field shows the typed text and caret", node and node.p.text == "ab" and node.p.cursor == 2, node and serde.encode("json", node.p))
	check("typing draws the panel again", cx.renders > 0)
	check("typing is handled, not left to the terminal", press(state, cx, "c", "c") == true)

	type_text(state, cx, "é😀")
	check("Unicode text is kept whole", state.fields.f_filter.text == "abcé😀", state.fields.f_filter.text)
	node = shown(state, cx, "f_filter")
	check("the caret counts UTF-16 units (an emoji is two)", node.p.cursor == 6, node.p.cursor)

	press(state, cx, "backspace")
	check("backspace removes the whole emoji", state.fields.f_filter.text == "abcé", state.fields.f_filter.text)
	press(state, cx, "left")
	press(state, cx, "left")
	node = shown(state, cx, "f_filter")
	check("left moves the caret by characters", node.p.cursor == 2 and node.p.anchor == nil, node and serde.encode("json", node.p))
	press(state, cx, "left", nil, { shift = true })
	node = shown(state, cx, "f_filter")
	check("shift+left selects: anchor stays, caret moves", node.p.cursor == 1 and node.p.anchor == 2, node and serde.encode("json", node.p))
	type_text(state, cx, "X")
	check("typing replaces the selection", state.fields.f_filter.text == "aXcé", state.fields.f_filter.text)
	node = shown(state, cx, "f_filter")
	check("the selection is gone after replacing it", node.p.cursor == 2 and node.p.anchor == nil, node and serde.encode("json", node.p))

	press(state, cx, "home")
	press(state, cx, "delete")
	check("home then delete removes the first character", state.fields.f_filter.text == "Xcé", state.fields.f_filter.text)
	press(state, cx, "end")
	press(state, cx, "backspace")
	check("end then backspace removes a multi-byte character", state.fields.f_filter.text == "Xc", state.fields.f_filter.text)

	press(state, cx, "a", nil, { ctrl = true })
	check("select all selects the whole text", shown(state, cx, "f_filter").p.anchor == 0 and shown(state, cx, "f_filter").p.cursor == 2)
	pasted(state, cx, "novo\r\nnome")
	check("paste replaces the selection and drops line breaks in a one-line field", state.fields.f_filter.text == "novonome", state.fields.f_filter.text)

	press(state, cx, "2", "@", { ctrl = true, alt = true })
	check("AltGr text (ctrl+alt) is typed", state.fields.f_filter.text == "novonome@", state.fields.f_filter.text)
	check("a ctrl chord types nothing and is not claimed", press(state, cx, "x", nil, { ctrl = true }) == false)
	check("a cmd chord with text types nothing", press(state, cx, "x", "x", { meta = true }) == false and state.fields.f_filter.text == "novonome@")
	check("an unnamed control character is not text", press(state, cx, "tab", "\t") == false and state.fields.f_filter.text == "novonome@")
	press(state, cx, "space", nil)
	check("space without text still types a space", state.fields.f_filter.text == "novonome@ ", state.fields.f_filter.text)
	check("the filter drives the store", panel.view(state, cx) ~= nil and state.store.filter == "novonome@ ", state.store.filter)
end

-- A field that has no focus is not typed into ------------------------------------------------------------------------
do
	local state, cx = open(nil)
	state.focus_field = nil
	check("with no field focused, text is left alone", press(state, cx, "z", "z") == false and state.fields.f_filter.text == "")
	press(state, cx, "n", "n")
	check("with no field focused, n opens the create dialog", state.store.modal == "create", state.store.modal)
end

-- Create form -----------------------------------------------------------------------------------------------------
do
	local state, cx = open({ "create" })
	check("the name has the keyboard on the create form", state.focus_field == "f_name", state.focus_field)
	local submit = find(panel.view(state, cx).layer, function(n)
		return n.p and n.p.actions and n.p.actions.click == "submit"
	end)
	check("Create starts disabled", submit and submit.p.disabled ~= nil)
	type_text(state, cx, "meu-ws")
	check("the name takes typed keys", state.fields.f_name.text == "meu-ws", state.fields.f_name.text)
	submit = find(panel.view(state, cx).layer, function(n)
		return n.p and n.p.actions and n.p.actions.click == "submit"
	end)
	check("typing a name enables Create", submit and submit.p.disabled == nil, submit and tostring(submit.p.disabled))
	panel.event(state, { ev = "focus", id = "layer.dialog.form.f_desc" }, cx)
	check("a click on the description moves the keyboard there", state.focus_field == "f_desc", state.focus_field)
	pasted(state, cx, "linha um\r\nlinha dois")
	check("paste into the description keeps one paragraph", state.fields.f_desc.text == "linha um linha dois", state.fields.f_desc.text)
	check("the name is unchanged by typing elsewhere", state.fields.f_name.text == "meu-ws")
end

-- Keys that carry only a name (the 0.9.15 repro logged {"name":"a","bytes":1}, no `text`) ---------------------------------
do
	local state, cx = open(nil)
	check("a printable key name with no text is typed", press(state, cx, "a") == true and state.fields.f_filter.text == "a", state.fields.f_filter.text)
	press(state, cx, "é")
	press(state, cx, "😀")
	press(state, cx, "+")
	check("a Unicode scalar or symbol name with no text is typed whole", state.fields.f_filter.text == "aé😀+", state.fields.f_filter.text)
	press(state, cx, "b", nil, { shift = true })
	check("shift with a letter name and no text types the capital", state.fields.f_filter.text == "aé😀+B", state.fields.f_filter.text)
	local before = state.fields.f_filter.text
	check("a function key name is not typed", press(state, cx, "f6") == false and state.fields.f_filter.text == before)
	check("a named editing key with no text is not typed", press(state, cx, "tab") == false and press(state, cx, "pageup") == false and state.fields.f_filter.text == before)
	check("alt plus a name with no text is not typed", press(state, cx, "b", nil, { alt = true }) == false and state.fields.f_filter.text == before)
	check("ctrl plus a name with no text is not typed", press(state, cx, "b", nil, { ctrl = true }) == false and state.fields.f_filter.text == before)
	check("cmd plus a name with no text is not typed", press(state, cx, "b", nil, { meta = true }) == false and state.fields.f_filter.text == before)
	press(state, cx, "a", nil, { ctrl = true })
	check("ctrl+a still selects all", shown(state, cx, "f_filter").p.anchor == 0)
	press(state, cx, "z")
	check("a name-only key replaces the selection", state.fields.f_filter.text == "z", state.fields.f_filter.text)
end

-- Search screen ----------------------------------------------------------------------------------------------------
do
	local state, cx = open({ "search" })
	check("the search field has the keyboard", state.focus_field == "f_query", state.focus_field)
	type_text(state, cx, "dev ws")
	check("the search text is typed", state.fields.f_query.text == "dev ws", state.fields.f_query.text)
	check("the search field shows it", shown(state, cx, "f_query").p.text == "dev ws")
end

-- Native edits remain UTF-16-correct; stale native edits must not overwrite newer key input --------------------------
do
	local state, cx = open({ "create" })
	panel.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 0, to = 0, len = 0, text = "x", cursor = 1 }, cx)
	check("an edit event still applies", state.fields.f_name.text == "x", state.fields.f_name.text)
	panel.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 1, to = 1, len = 1, text = "😀", cursor = 3 }, cx)
	check("native edits use UTF-16 offsets", state.fields.f_name.text == "x😀" and shown(state, cx, "f_name").p.cursor == 3, state.fields.f_name.text)
	panel.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 1, to = 3, len = 3, text = "", cursor = 1 }, cx)
	check("native edits delete a surrogate pair whole", state.fields.f_name.text == "x", state.fields.f_name.text)
end

do
	local state, cx = open({ "create" })
	press(state, cx, "😀", "😀")
	panel.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 0, to = 0, len = 0, text = "😀", cursor = 2 }, cx)
	check("a native edit computed before Unicode key input is skipped, not doubled", shown(state, cx, "f_name").p.text == "😀" and shown(state, cx, "f_name").p.cursor == 2, shown(state, cx, "f_name").p.text)
	press(state, cx, "a", "a")
	check("key input remains accepted after a stale native edit", shown(state, cx, "f_name").p.text == "😀a", shown(state, cx, "f_name").p.text)
	panel.event(state, { ev = "edit", id = "layer.dialog.form.f_name", from = 3, to = 3, len = 3, text = "語", cursor = 4 }, cx)
	check("a valid native Unicode edit applies after key input", shown(state, cx, "f_name").p.text == "😀a語" and shown(state, cx, "f_name").p.cursor == 4, shown(state, cx, "f_name").p.text)
end

-- Injected handoff, not claimed as the user's historical event sequence: a focused field receives a valid
-- native Unicode edit, is cleared natively with correct UTF-16 offsets, then receives key text without refocusing.
do
	local state, cx = open(nil)
	local id = "main.root.f_filter"
	panel.event(state, { ev = "edit", id = id, from = 0, to = 0, len = 0, text = "a😀b", cursor = 4 }, cx)
	local node = shown(state, cx, "f_filter")
	check("injected native Unicode edit is visible at its UTF-16 caret", node and node.p.text == "a😀b" and node.p.cursor == 4, node and serde.encode("json", node.p))

	panel.event(state, { ev = "edit", id = id, from = 0, to = 4, len = 4, text = "", cursor = 0 }, cx)
	node = shown(state, cx, "f_filter")
	check("injected native clear with the current UTF-16 length is visible", node and node.p.text == "" and node.p.cursor == 0, node and serde.encode("json", node.p))
	type_text(state, cx, "語😀")
	node = shown(state, cx, "f_filter")
	check("key text after native clear refills the visible field once", node and node.p.text == "語😀" and node.p.cursor == 3, node and serde.encode("json", node.p))
end

-- Collection scope controls must reach the query, while modal controls remain an unapplied draft.
do
	Dev.pull_requests = function(input, done)
		done({ ok = true, value = if input.scope == "all" then { { id = 2, title = "Other author" } } else { { id = 1, title = "Mine" } } }, nil)
	end
	local state, cx = open(nil)
	state.store.screen = "prs"
	panel.event(state, { ev = "action", act = "prs.scope", value = "all" }, cx)
	check("All PRs on the native collection commits its scope", state.store.pr_query.scope == "all")
	check("All PRs shows the other author's cached result", state.store.prs and state.store.prs[1].id == 2)
	local visible = serde.encode("json", panel.view(state, cx).main)
	check("the native collection labels the applied All PRs query", string.find(visible, "Showing All PRs", 1, true) ~= nil)
	panel.event(state, { ev = "action", act = "prs.filters" }, cx)
	panel.event(state, { ev = "action", act = "prs.scope", value = "mine" }, cx)
	panel.event(state, { ev = "action", act = "prs.status", value = "closed" }, cx)
	check("filter choices remain a draft before Apply", state.store.pr_query.scope == "all" and state.store.pr_query.status == "open" and state.store.prs[1].id == 2)
	panel.event(state, { ev = "action", act = "submit" }, cx)
	check("Apply commits the modal scope and status together", state.store.pr_query.scope == "mine" and state.store.pr_query.status == "closed" and state.store.prs and state.store.prs[1].id == 1)
end

-- Opening an editor from a fresh panel must populate its repository chooser from cache.
do
	Dev.catalog = answers({
		{ name = "api", url = "https://example.test/north/api", project = "North" },
		{ name = "api", url = "https://example.test/south/api", project = "South" },
	})
	Dev.workset = answers({ name = "recipe", members = {} })
	for _, action in { "workset.new", "workset.edit", "add" } do
		local state, cx = open(nil)
		state.store.workspaces = { { name = "fixture", path = "C:/dev-root/ws/fixture" } }
		panel.event(state, { ev = "action", act = action, value = if action == "add" then "fixture" else "recipe" }, cx)
		if action ~= "add" then panel.event(state, { ev = "action", act = "member.new", value = "repository" }, cx) end
		panel.event(state, { ev = "action", act = "select.open", value = if action == "add" then "add.repo" else "member.source" }, cx)
		local visible = serde.encode("json", panel.view(state, cx).layer)
		check(action .. " offers both cached homonymous repositories", string.find(visible, "https://example.test/north/api", 1, true) ~= nil and string.find(visible, "https://example.test/south/api", 1, true) ~= nil)
	end
end

-- Secrets in diagnostic text -------------------------------------------------------------------------------------------
do
	local secrets = { "ghp_abcdefghijklmnop", "hunter2", "abc.def.ghi", "s3cr3t" }
	local function leaks(text: string): string?
		for _, secret in secrets do
			if string.find(text, secret, 1, true) then
				return secret
			end
		end
		return nil
	end

	Dev.doctor = function(_, done)
		done({
			ok = true,
			value = {
				status = "degraded",
				root = { path = "C:/dev-root", exists = true, hasDevDir = true },
				checks = {
					{ id = "gh", label = "gh", status = "error", durationMs = 12, message = "auth failed: token=ghp_abcdefghijklmnop for https://me:s3cr3t@github.com/x" },
				},
				messages = { "Authorization: Bearer abc.def.ghi", { message = "password=hunter2" } },
			},
		}, nil)
	end
	local state, cx = open(nil)
	panel.event(state, { ev = "action", act = "settings" }, cx)
	panel.event(state, { ev = "action", act = "doctor" }, cx)
	local encoded = serde.encode("json", panel.view(state, cx).layer)
	check("settings show the doctor report", string.find(encoded, "auth failed", 1, true) ~= nil, encoded)
	check("settings never print a credential from a doctor check or message", leaks(encoded) == nil, leaks(encoded))

	local wcx = Shim.window_cx()
	Shim.cx = wcx
	Dev.set_description = function(_, done)
		done({ ok = false, error = { message = "Could not write token=ghp_abcdefghijklmnop", detail = "https://me:s3cr3t@github.com/x password=hunter2" } }, nil)
	end
	wcx.prompt_answer = "new text"
	Shim.route({ url = "devcli://describe?ws=alpha&path=C%3A%2Fdev-root%2Falpha&text=old" }, wcx)
	local toast = wcx.record.toasts[#wcx.record.toasts]
	check("a failed description save raises an error toast", toast ~= nil and toast.level == "error", toast and serde.encode("json", toast))
	check("the toast never prints a credential", toast ~= nil and leaks(tostring(toast.text) .. "\n" .. tostring(toast.sub)) == nil, toast and serde.encode("json", toast))
end

print(string.format("\n%d failed", #failures))
if #failures > 0 then
	for _, name in failures do
		print("  - " .. name)
	end
	process.exit(1)
end
