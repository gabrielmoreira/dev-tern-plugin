--!nonstrict
-- Editable native navigator, shared by sidebar and panel placements.
-- Window-only effects go through the `devcli://` route; dialogs stay in this block's native layer.

local Store = require("./store")
local View = require("./view")
local DevCli = require("./devcli")
local ShellEnv = require("./shellenv")
local Redaction = require("./redaction")
local Forms = require("./forms")
require("./lenses")

local ui = tern.ui
local POLL_MS = 60 * 1000
-- How often the block looks for a change another surface made (kv "changed", stamped by the window half).
local TICK_MS = 2 * 1000

-- Field ids are the keyed path: region `main`, the view root `root`, then `form`/`ask` for their fields.
local FIELD_PATH = {
	f_filter = "main.root.f_filter",
	f_query = "main.root.f_query",
	f_ask = "main.root.ask.f_ask",
}
for _, key in Forms.keys do FIELD_PATH[key] = "layer.dialog.form." .. key end

-- Fields that outlive the create/add forms.
local KEEP = { f_filter = true, f_query = true, f_ask = true }

local running: { [number]: any } = {}
local Panel
local settings_view, settings_event
local doctor_view, doctor_context_matches

local function units(text: string): number
	local n = 0
	for _, cp in utf8.codes(text) do
		n += if cp > 0xFFFF then 2 else 1
	end
	return n
end

local function bytes(text: string, offset: number): number
	local n = 0
	for pos, cp in utf8.codes(text) do
		local width = if cp > 0xFFFF then 2 else 1
		if n + width > offset then
			return pos - 1
		end
		n += width
	end
	return #text
end

local function encode(text: string): string
	return (string.gsub(text, "[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function alive(state): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	return false
end

local function field(state, key: string): string
	return state.fields[key].text
end

-- The selection's far end as a UTF-16 offset, nil when nothing is selected.
local function anchor_units(f): number?
	if f.anchor and f.anchor ~= f.cursor then
		return units(string.sub(f.text, 1, f.anchor))
	end
	return nil
end

local function input(state, key: string, placeholder: string, aria: string)
	local f = state.fields[key]
	return ui.node("input", {
		key = key,
		text = f.text,
		cursor = units(string.sub(f.text, 1, f.cursor)),
		anchor = anchor_units(f),
		placeholder = placeholder,
		aria = aria,
	})
end

-- A wrapping multi-line field; newlines are dropped on edit, so it holds one paragraph.
local function editor(state, key: string, placeholder: string)
	local f = state.fields[key]
	return ui.node("editor", {
		key = key,
		text = f.text,
		cursor = units(string.sub(f.text, 1, f.cursor)),
		anchor = anchor_units(f),
		maxLines = 6,
		placeholder = placeholder,
	})
end

local function label(text: string)
	return ui.text(ui.span(text, "muted strong"))
end

local function choice(text: string, action: string, on: boolean, disabled: string?)
	return View.button(text, action, { on = on, variant = if on then "primary" else "default", disabled = disabled })
end

local form_values = Forms.values
local validate = Forms.validate
local submit = Forms.submit
local reset_form = Forms.reset
local set_field = Forms.set_field

-- Byte offset of the character boundary before / after `at`.
local function boundary_before(text: string, at: number): number
	if at <= 0 then
		return 0
	end
	return (utf8.offset(text, -1, at + 1) or 1) - 1
end

local function boundary_after(text: string, at: number): number
	if at >= #text then
		return #text
	end
	local nxt = utf8.offset(text, 2, at + 1)
	return if nxt then nxt - 1 else #text
end

-- Replaces bytes (from, to] and puts the caret after the replacement.
local function replace(f, from: number, to: number, text: string)
	f.text = string.sub(f.text, 1, from) .. text .. string.sub(f.text, to + 1)
	f.cursor, f.anchor = from + #text, nil
end

-- Edits a field from a key. A field with focus and shown to the user accepts typed text, paste and caret keys as
-- `key` events, regardless of whether earlier changes arrived as native `edit` events.
-- Returns whether the key was used.
local function edit_key(f, key: Key, paragraph: boolean): boolean
	local cursor = math.clamp(f.cursor, 0, #f.text)
	local anchor = f.anchor
	local lo, hi = cursor, cursor
	if anchor then
		lo, hi = math.min(anchor, cursor), math.max(anchor, cursor)
	end
	local name = key.name
	if ((key.ctrl and not key.alt) or key.meta) and name == "a" then
		f.anchor, f.cursor = 0, #f.text
		return true
	elseif name == "left" or name == "right" or name == "home" or name == "end" then
		local target
		if name == "home" then
			target = 0
		elseif name == "end" then
			target = #f.text
		elseif lo ~= hi and not key.shift then
			target = if name == "left" then lo else hi
		else
			target = if name == "left" then boundary_before(f.text, cursor) else boundary_after(f.text, cursor)
		end
		f.anchor = if key.shift then (anchor or cursor) else nil
		f.cursor = target
		return true
	elseif name == "backspace" or name == "delete" then
		if lo == hi then
			if name == "backspace" then
				lo = boundary_before(f.text, cursor)
			else
				hi = boundary_after(f.text, cursor)
			end
		end
		if lo == hi then
			return false
		end
		replace(f, lo, hi, "")
		return true
	end
	local text = key.text
	if name == "paste" then
		text = (string.gsub(text or "", "[\r\n]+", if paragraph then " " else ""))
	elseif key.meta or (key.ctrl and not key.alt) then
		return false -- a chord; ctrl+alt is AltGr, which types
	elseif text == nil and name == "space" then
		text = " "
	elseif text == nil and not (key.ctrl or key.alt) and utf8.len(name) == 1 then
		-- Tern may send the typed character as the key's name with no `text`; named keys (enter, f6, tab) are longer.
		text = if key.shift then string.upper(name) else name
	end
	if type(text) ~= "string" or text == "" or string.find(text, "%c") then
		return false
	end
	replace(f, lo, hi, text)
	return true
end

-- The fields this screen draws, by key.
local function shown_fields(state): { [string]: boolean }
	local s = state.store
	local out = {}
	if state.settings then return out end
	local mode = s.modal
	if mode then
		return Forms.shown(state)
	elseif state.queries[s.screen] ~= nil then
		out.f_filter = true
	elseif s.screen == "search" then
		out.f_query = true
	end
	if not mode and s.ask and Store.question(s.ask.kind, s.ask.mount) then
		out.f_ask = true
	end
	return out
end

-- The field that takes typing on this screen: an asked value first, else the screen's own field.
local function focus_first(state)
	local s = state.store
	local screen = s.modal or s.screen
	local key = if state.settings then nil
		elseif s.modal then Forms.first(state)
		elseif s.ask then "f_ask"
		elseif screen == "search" then "f_query"
		elseif state.queries[screen] ~= nil then "f_filter"
		else nil
	state.focus_field = key
	if key then
		state.cx:frame({ { "focus", FIELD_PATH[key] } })
	end
end

-- After a click or key: a new question gets its field (prefilled) and the screen's field gets focus.
local function settle(state, before_screen: string, before_ask)
	local s = state.store
	Forms.sync(state)
	if s.screen ~= before_screen then
		if state.queries[before_screen] ~= nil then state.queries[before_screen] = field(state, "f_filter") end
		if state.queries[s.screen] ~= nil then set_field(state, "f_filter", state.queries[s.screen]) end
	end
	if s.ask and s.ask ~= before_ask then set_field(state, "f_ask", s.ask.value) end
	local dialog = if state.settings then "settings" else s.modal
	if dialog ~= state.dialog_seen then
		local closing = state.dialog_seen ~= nil and dialog == nil
		state.dialog_seen = dialog
		if closing and state.return_focus and shown_fields(state)[state.return_focus] then
			state.focus_field = state.return_focus
			state.cx:frame({ { "focus", FIELD_PATH[state.return_focus] } })
		else
			focus_first(state)
		end
	elseif s.screen ~= before_screen or s.ask ~= before_ask then
		focus_first(state)
	end
end

-- Moves the keyboard selection over the workspace rows on screen; `step` is +1 or -1.
local function move_cursor(s, step: number)
	local order = View.order(s)
	if #order == 0 then
		s.cursor = nil
		return
	end
	local at = table.find(order, s.cursor or "")
	if not at then
		s.cursor = if step > 0 then order[1] else order[#order]
	else
		s.cursor = order[math.clamp(at + step, 1, #order)]
	end
end

-- Reloads when the window half stamped a change (a description saved there, a sidebar action), and at least
-- every POLL_MS.
local function poll(state)
	state.timer = tern.timer(TICK_MS, function()
		state.timer = nil
		if not alive(state) then
			return
		end
		local stamp = tern.kv.get("changed")
		if stamp ~= state.seen or tern.now() - state.polled >= POLL_MS then
			state.seen, state.polled = stamp, tern.now()
			Store.refresh(state.store, nil)
		end
		poll(state)
	end)
end

-- Only an explicit placement requests sizing; later manual divider changes remain untouched.
local function report_width(state, cx)
	if not state.width_request or not state.cols or state.cols <= 0 then return end
	local request = state.width_request
	state.width_request = nil
	cx:open("devcli://sidebar.width?pane=" .. tostring(cx.pane) .. "&cols=" .. tostring(state.cols) .. "&request=" .. request)
end

local function measure_width(state, cx)
	if state.width_timer then state.width_timer:cancel() end
	-- A move reaches the host asynchronously; wait for destination resize events to settle.
	state.width_timer = tern.timer(120, function()
		state.width_timer = nil
		if alive(state) then report_width(state, cx) end
	end)
end

Panel = {
	features = { "edit" },
	font = "sans",

	init = function(cx: BlockCx, args: { string }, _saved: any)
		local previous = running[cx.pane]
		if previous and previous.timer then
			previous.timer:cancel()
		end
		local state
		state = {
			cx = cx,
			queries = { home = "", worksets = "", mirrors = "", prs = "", wis = "" },
			fields = {
				f_filter = { text = "", cursor = 0 },
				f_query = { text = "", cursor = 0 },
				f_ask = { text = "", cursor = 0 },
			},
			form = nil,
			validate = validate,
			form_values = form_values,
			seen = tern.kv.get("changed"), -- last change stamp this block reloaded for
			polled = tern.now(),
		}
		reset_form(state)
		state.store = Store.new({
			surface = "block",
			dev = DevCli,
			redraw = function(_)
				settle(state, state.store.screen, state.store.ask)
				if alive(state) then
					cx:render()
				end
			end,
			effect = function(_, kind: string, data)
				if kind == "settings" then
					state.settings = true
					settle(state, state.store.screen, state.store.ask)
					cx:render()
					return
				end
				if kind == "copy" then
					cx:copy(data.text)
					cx:toast("info", "Copied", Redaction.text(data.text))
					return
				end
				local query = {}
				for k, v in data do
					table.insert(query, encode(tostring(k)) .. "=" .. encode(tostring(v)))
				end
				table.sort(query)
				cx:open("devcli://" .. kind .. (if #query > 0 then "?" .. table.concat(query, "&") else ""))
			end,
		})
		running[cx.pane] = state
		local mode = args and args[1]
		if mode == "create" then
			state.store.modal = "create"
			state.store.after_load = function(c) Store.load_sources(state.store, c) end
		elseif mode == "add" and args[2] then
			state.store.modal_ws = args[2]
			state.store.modal = "add"
		elseif mode == "ws" and args[2] then
			state.store.selected = args[2]
			state.store.screen = "ws"
		elseif mode == "settings" then
			state.settings = true
		elseif mode == "search" then
			state.store.screen = "search"
			set_field(state, "f_query", args[2])
			if args[2] and args[2] ~= "" then
				state.store.after_load = function(c) Store.search(state.store, c, args[2]) end
			end
		end
		Store.refresh(state.store, nil)
		poll(state)
		-- Defer until this block is mounted, so the window can address its initial presence observation.
		tern.timer(0, function()
			if alive(state) then cx:open("devcli://presence.refresh") end
		end)
		return state
	end,

	title = function(state): string?
		local s = state.store
		if (s.screen == "ws" or s.screen == "add") and s.selected then
			return "dev · " .. tostring(s.selected)
		elseif s.screen == "create" then
			return "dev · new workspace"
		elseif s.screen == "search" then
			return "dev · search"
		end
		return "dev"
	end,

	view = function(state, _cx: BlockCx): BlockView
		local s = state.store
		s.filter = field(state, "f_filter")
		local opts = {}
		if state.queries[s.screen] ~= nil then
			opts.filter = input(state, "f_filter", "Search " .. (if s.screen == "home" then "workspaces" elseif s.screen == "worksets" then "worksets" elseif s.screen == "prs" then "pull requests" elseif s.screen == "wis" then "work items" else "mirrors") .. "…", "Search collection")
		elseif s.screen == "search" then
			opts.query = input(state, "f_query", "Search mirror contents (qmd) · Enter searches", "Search mirror contents")
		end
		if s.ask then
			local q = Store.question(s.ask.kind, s.ask.mount)
			if q then
				opts.ask = input(state, "f_ask", q.text, q.text)
			end
		end
		local main, dock = View.render(s, opts)
		local layer = ui.col({})
		if state.settings or s.modal then
			local body = if state.settings then settings_view(state) else Forms.render(state, input, editor)
			local children = {
				View.button("", "modal.close", { key = "close", icon = "x", variant = "quiet", title = "Close dialog" }),
				body,
			}
			if not state.settings then
				table.insert(children, View.with(ui.row(Forms.footer(state)), { key = "dialog-foot", role = View.role("dialog-foot") }))
			end
			-- Tern does not draw region roots; a child overlay owns the native header, body and footer.
			layer = ui.col({ ui.node("overlay", {
				key = "dialog", modal = true, size = "md", role = View.role("dialog"),
				head = if state.settings then "dev settings" else Forms.title(state),
				["end"] = "layer.dialog.close", foot = if state.settings then nil else "layer.dialog.dialog-foot",
				actions = { close = "modal.close" },
			}, children) })
		end
		return { main = main, dock = dock, layer = layer }
	end,

	resize = function(state, cols: number, _rows: number, cx: BlockCx)
		state.cols = cols
		if state.width_request then
			measure_width(state, cx)
		else
			cx:open("devcli://sidebar.width?pane=" .. tostring(cx.pane) .. "&cols=" .. tostring(cols))
		end
		if state.focus_field == nil then focus_first(state) end
	end,

	key = function(state, key: Key, cx: BlockCx): boolean?
		local s = state.store
		local screen, ask = s.screen, s.ask
		local name = key.name
		if not s.modal and not state.settings and screen == "home" and not state.focus_field and not (key.ctrl or key.alt or key.meta) then
			if name == "/" then
				focus_first(state)
				return true
			elseif name == "n" then
				reset_form(state)
				Store.dispatch(s, cx, "create", nil)
				settle(state, screen, ask)
				return true
			end
		end
		if s.modal and Forms.key(state, key, cx) then cx:render() return true end
		if name == "escape" or name == "esc" then
			if state.settings or s.modal then
				state.settings = nil
				Store.dispatch(s, cx, "modal.close", nil)
			elseif s.ask then
				s.ask = nil
			elseif s.screen == "home" and field(state, "f_filter") ~= "" then
				set_field(state, "f_filter", "")
				s.cursor = nil
			elseif s.screen == "home" then
				return false
			else
				Store.dispatch(s, cx, "back", nil)
			end
			settle(state, screen, ask)
			return true
		elseif name == "enter" and not state.settings and not s.modal and s.ask then
			Store.answer(s, cx, s.ask, field(state, "f_ask"))
			settle(state, screen, ask)
			return true
		elseif name == "enter" and s.modal then
			submit(state, cx)
			return true
		elseif name == "enter" and not state.settings and not s.modal and s.screen == "search" then
			Store.search(s, cx, field(state, "f_query"))
			return true
		elseif not state.settings and not s.modal and s.screen == "home" and (name == "up" or name == "down") and not (key.ctrl or key.alt or key.meta) then
			s.filter = field(state, "f_filter")
			move_cursor(s, if name == "down" then 1 else -1)
			return true
		elseif not state.settings and not s.modal and name == "enter" and s.screen == "home" then
			-- The selected row, else the first one on screen (type a few letters, Enter).
			s.filter = field(state, "f_filter")
			local order = View.order(s)
			local target = if s.cursor and table.find(order, s.cursor) then s.cursor else order[1]
			if not target then
				return false
			end
			Store.dispatch(s, cx, "ws", target)
			settle(state, screen, ask)
			return true
		elseif not state.settings and not s.modal and name == "enter" and s.screen == "ws" and s.selected and not (key.ctrl or key.alt or key.meta) then
			Store.dispatch(s, cx, "open", s.selected)
			return true
		elseif not state.settings and not s.modal and name == "f5" then
			Store.refresh(s, cx, true)
			return true
		end
		-- Typed text, paste and caret keys edit the currently focused field.
		local focused = state.focus_field
		if focused and shown_fields(state)[focused] and edit_key(state.fields[focused], key, focused == "f_desc") then
			Forms.changed(state, focused)
			if focused == "f_filter" then
				s.cursor = nil -- a new filter starts the selection over at the first match
				s.pages[s.screen] = 1
			end
			return true
		end
		return false
	end,

	event = function(state, ev: UiEvent, cx: BlockCx)
		local s = state.store
		if ev.ev == "action" and ev.act == "sidebar.measure" then
			state.width_request = ev.value
			measure_width(state, cx)
			return
		end
		if ev.ev == "action" and ev.act == "presence.snapshot" then
			local ok, observation = pcall(tern.json.decode, ev.value)
			if not ok or type(observation) ~= "table"
				or (observation.available == true and (type(observation.sessions) ~= "table"
					or type(observation.tabs) ~= "table" or type(observation.panes) ~= "table")) then
				observation = { available = false, complete = false }
			end
			Store.set_presence(s, observation)
			cx:render()
			return
		end
		if ev.ev == "action" and ev.act == "active" then
			if Store.norm(ev.root) == Store.norm(s.active_root) then s.active_ws = ev.value cx:render() end
			return
		end
		local id = type(ev.id) == "string" and ev.id or ""
		local key = string.match(id, "([^%.]+)$")
		local f = key and state.fields[key]
		if f and not shown_fields(state)[key] then return end
		if f and ev.ev == "focus" then
			state.focus_field = key
			cx:frame({ { "focus", id } })
			return
		elseif f and ev.ev == "edit" then
			state.focus_field = key
			-- Offsets are UTF-16 [from, to); skip edits computed against an older text (keys in flight).
			if type(ev.from) ~= "number" or type(ev.to) ~= "number" or type(ev.text) ~= "string" or ev.len ~= units(f.text) then
				return
			end
			local first, last = bytes(f.text, math.min(ev.from, ev.to)), bytes(f.text, math.max(ev.from, ev.to))
			local text = string.gsub(ev.text, "[\r\n]+", if key == "f_desc" then " " else "")
			f.text = string.sub(f.text, 1, first) .. text .. string.sub(f.text, last + 1)
			f.cursor = if type(ev.cursor) == "number" then bytes(f.text, ev.cursor) else first + #text
			f.anchor = nil
			Forms.changed(state, key)
			if key == "f_filter" then
				-- A new filter starts the selection over at the first match.
				s.cursor = nil
				s.pages[s.screen] = 1
			end
			-- What the form shows hangs on the text (Create enabled, the name-taken notice): draw it again.
			cx:render()
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then
			return
		end
		local act, value = ev.act, ev.value
		if act == "close" and (state.settings or s.modal) then
			state.settings = nil
			Store.dispatch(s, cx, "modal.close", nil)
			settle(state, s.screen, s.ask)
			cx:render()
			return
		end
		if state.settings then
			settings_event(state, ev, cx)
			settle(state, s.screen, s.ask)
			return
		end
		if s.modal == "create" and act == "ws" and value == field(state, "f_name") and Store.workspace(s, value) then
			Store.dispatch(s, cx, "modal.close", nil)
		end
		if s.modal and not Forms.allows(act) then return end
		local screen, ask = s.screen, s.ask
		if (act == "create" or act == "add" or act == "settings") and not s.modal then state.return_focus = state.focus_field end
		if act == "modal.close" then
			Store.dispatch(s, cx, "modal.close", nil)
		elseif act == "submit" then
			submit(state, cx)
			cx:render()
		elseif Forms.action(state, cx, act, value) then
			if act == "src" or not shown_fields(state)[state.focus_field] then focus_first(state) end
			cx:render()
		elseif act == "ask.submit" and s.ask then
			Store.answer(s, cx, s.ask, field(state, "f_ask"))
		elseif act == "search" and (value == nil or value == "") then
			-- The block has a field: the search screen instead of a question.
			s.screen = "search"
			s.ask = nil
			if s.search then
				set_field(state, "f_query", s.search.query)
			end
		else
			if act == "create" or act == "add" or act == "workset.new" or act == "workset.edit" or act == "workset.create" then
				reset_form(state)
			end
			Store.dispatch(s, cx, act, value)
		end
		settle(state, screen, ask)
	end,
}

-- The plugin's settings: which surface "dev: Open" shows (the window half applies a change at once through
-- `devcli://surface`), and dev doctor's report of tools and providers.
doctor_view = function(d)
	if not d then
		return { View.hint("Checks git, bun and the optional tools, the root, and each provider's credentials.") }
	end
	local out = {}
	if d.loading then table.insert(out, ui.progress(nil, "Running dev doctor…")) end
	if d.error then table.insert(out, View.error_card("dev doctor failed", d.error, "doctor-error")) end
	if not d.data then return out end
	if d.loading or d.error then table.insert(out, View.hint("Last successful report, not a current health assessment.")) end
	local r = d.data
	local ok = r.status == "healthy"
	table.insert(out, ui.row({
		ui.badge(tostring(r.status or "?"), if ok then "success" elseif r.status == "error" then "error" else "warning"),
		ui.text(ui.span(tostring((r.root or {}).path or ""), "mono")),
	}))
	local root = r.root or {}
	if root.exists == false or root.hasDevDir == false then
		table.insert(out, View.hint(if root.exists == false then "The root folder does not exist." else "The root has no .dev folder: dev init sets it up."))
	end
	if type(r.checks) == "table" then
		table.insert(out, label("Checks"))
		for _, check in r.checks do
			local body = { ui.row({
				ui.text(ui.span(tostring(check.label or check.id), "strong")),
				ui.badge(tostring(check.status), if check.status == "ok" then "success" elseif check.status == "error" then "error" else "warning"),
				ui.text(ui.span(tostring(math.floor(tonumber(check.durationMs) or 0)) .. " ms", "muted")),
			}) }
			if check.message then table.insert(body, View.hint(Redaction.text(check.message))) end
			table.insert(out, View.with(ui.col(body), { key = tostring(check.id), role = View.role("plan-row") }))
		end
	else
	local tools = {}
	for _, t in r.tools or {} do
		local tone = if t.available then "success" elseif t.required then "error" else "muted"
		local state = if t.available then "found" elseif t.required then "missing" else "absent"
		table.insert(tools, View.with(ui.row({
			ui.text({ ui.span(tostring(t.name), "strong"), ui.span(if t.required then "" else "  optional", "muted") }),
			ui.text(ui.span(View.bounded(tostring(t.version or ""), 40), "muted")),
			ui.badge(state, tone),
		}), { key = "tool:" .. tostring(t.name), role = View.role("plan-row") }))
	end
	if #tools > 0 then
		table.insert(out, label("Tools"))
		table.insert(out, View.with(ui.col(tools), { key = "tools", role = View.role("list") }))
	end
	local providers = {}
	for _, p in r.providerList or {} do
		table.insert(providers, View.with(ui.row({
			ui.text({ ui.span(tostring(p.id), "strong"), ui.span("  " .. tostring(p.type) .. " · " .. Redaction.text(p.target or ""), "muted") }),
			ui.badge(if p.configured then tostring(p.credentialSource or "configured") else "not configured", if p.configured then "success" else "warning"),
		}), { key = "provider:" .. tostring(p.id), role = View.role("plan-row") }))
	end
	if #providers > 0 then
		table.insert(out, label("Providers"))
		table.insert(out, View.with(ui.col(providers), { key = "providers", role = View.role("list") }))
	end
	end
	for i, m in r.messages or {} do
		local text = Redaction.text(if type(m) == "table" then (m.message or m.text or tern.json.encode(m)) else m)
		table.insert(out, View.with(View.hint(text), { key = "doctor-msg" .. i }))
	end
	return out
end

doctor_context_matches = function(entry)
	return entry.root == tern.kv.get("root") and entry.revision == ShellEnv.config().revision
end

settings_view = function(state)
		local current = if tern.kv.get("surface") == "panel" then "panel" else "sidebar"
		local config = ShellEnv.config()
		if state.doctor and not doctor_context_matches(state.doctor) then state.doctor = nil end
		local function choice(text: string, value: string)
			local on = current == value
			return View.button(text, "surface=" .. value, { on = on, variant = if on then "primary" else "default", size = "md" })
		end
		local side = if tern.kv.get("sidebar_side") == "left" then "left" else "right"
		local function side_choice(text: string, value: string)
			local on = side == value
			return View.button(text, "sidebar.side=" .. value, { on = on, variant = if on then "primary" else "default", size = "md" })
		end
		local kids = {
			label("Open dev as"),
			View.with(ui.row({ choice("Sidebar · follows tabs", "sidebar"), choice("Panel · stays in tab", "panel") }), { role = View.role("choices") }),
			View.hint("Same navigator and data. Sidebar moves to the active tab on the chosen side. Panel opens beside the focused block and stays in that tab when you switch tabs. dev: Open (Ctrl+Alt+Shift+D) shows the chosen mode in the current tab."),
			label("Sidebar side"),
			View.with(ui.row({ side_choice("Left", "left"), side_choice("Right", "right") }), { role = View.role("choices") }),
			View.hint("Right by default. The side is remembered across tabs; existing content blocks keep their arrangement."),
			label("Execution environment"),
			ui.text(if config.mode == "shell" then tostring(config.kind) .. " · " .. tostring(config.shell) else "Inherited from Tern (default)"),
			View.hint("Inherited mode never runs profiles. Opting into shell initialization executes all startup commands, including credential tools, in each command directory. Variables are cached only in memory."),
			ui.row({
				View.button("Choose environment…", "environment", { icon = "terminal", size = "md" }),
				View.button("Refresh environment", "environment.refresh", { icon = "refresh", size = "md", disabled = if config.mode == "shell" then nil else "Inherited mode uses Tern's current environment" }),
			}),
			label("dev selection"),
			ui.code(if config.mode == "shell" then "DEV_TERN_BIN, then the initialized PATH in the operation's directory" else DevCli.binary(), "sh"),
			View.hint("Commands use their workspace directory, or the selected root; discovery uses the home directory. Errors show the executable and directory actually used. DEV_TERN_BIN is an explicit override."),
			View.with(ui.row({
				label("Health"),
				View.button(if state.doctor then "Run again" else "Run dev doctor", "doctor", {
					icon = "refresh",
					size = "md",
					busy = state.doctor ~= nil and state.doctor.loading,
				}),
			}), { role = View.role("plan-row"), key = "doctor-head" }),
		}
		for _, n in doctor_view(state.doctor) do
			table.insert(kids, n)
		end
		return View.with(ui.col(kids), { key = "settings", role = View.role("form") })
end

settings_event = function(state, ev: UiEvent, cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "modal.close" then state.settings = nil return end
		if ev.act == "surface" and (ev.value == "sidebar" or ev.value == "panel") then
			tern.kv.set("surface", ev.value)
			cx:open("devcli://surface?value=" .. ev.value)
			cx:render()
		elseif ev.act == "sidebar.side" and (ev.value == "left" or ev.value == "right") then
			tern.kv.set("sidebar_side", ev.value)
			cx:open("devcli://sidebar.side?value=" .. ev.value)
			cx:render()
		elseif ev.act == "environment" then
			cx:open("devcli://environment")
		elseif ev.act == "environment.refresh" then
			state.doctor = nil
			cx:open("devcli://environment.refresh")
			cx:render()
		elseif ev.act == "doctor" and not (state.doctor and state.doctor.loading) then
			local previous = state.doctor
			local entry = {
				loading = true, root = tern.kv.get("root"), revision = ShellEnv.config().revision,
				data = if previous and doctor_context_matches(previous) then previous.data else nil,
			}
			state.doctor = entry
			cx:render()
			DevCli.doctor({ root = entry.root }, function(r, _)
				if state.doctor ~= entry or not doctor_context_matches(entry) or not alive(state) then return end
				entry.loading = false
				if r.ok then
					entry.data = r.value
				else
					entry.error = r.error
				end
				if state.doctor == entry then
					cx:render()
				end
			end)
		end
end

tern.block.define("panel", Panel)
