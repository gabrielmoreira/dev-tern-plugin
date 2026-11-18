--!nonstrict
-- Node trees for the navigator block. A fixed toolbar, the native collection filter and the alerts sit above one
-- scrolling `devcli.body`. The host hands in the native inputs (`opts.filter`, `opts.query`, `opts.ask`);
-- New, Add and Settings are composed by the host into the block's overlay, never into this tree. Every click is
-- an action `name` or `name=value`; Tern splits `=` into `act` and `value`.

local Store = require("./store")
local Redaction = require("./redaction")

local ui = tern.ui
local View = {}

local PAGE = 50 -- rows per presentation page; filtering always runs over the whole inventory first
local MAX_DESC = 60 -- one line in a narrow sidebar; the full text is on the workspace screen
local MAX_NAME = 32 -- the row's tooltip carries the full name
local DIR_PAGE = 100 -- entries drawn per folder page; Prev/Next reach the rest

local function role(name: string): string
	return "devcli." .. name
end

local function with(node, props: { [string]: any })
	local p = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- Cuts at a code point boundary so multi-byte names never end in a broken character.
local function bounded(text: string?, limit: number): string
	local value = tostring(text or "")
	local n = utf8.len(value)
	if n == nil then
		return if #value <= limit then value else string.sub(value, 1, limit) .. "…"
	end
	if n <= limit then
		return value
	end
	return string.sub(value, 1, (utf8.offset(value, limit + 1) :: number) - 1) .. "…"
end

local function act(name: string, value: string?): string
	if value then
		return name .. "=" .. value
	end
	return name
end

local function button(text: string, action: string?, props: { [string]: any }?)
	local p = { actions = { click = action }, size = "sm" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return ui.button(text, p)
end

local function short_sha(sha: string?): string
	return if type(sha) == "string" then string.sub(sha, 1, 8) else ""
end

local function card(head, children, props)
	return ui.card(head, children, props or {})
end

local function hint(text: string)
	return with(ui.text(ui.span(text, "muted")), { role = role("hint") })
end


local function safe_detail(text: string): string
	local out = {}
	local count = 0
	for line in string.gmatch(text, "[^\r\n]+") do
		count += 1
		if count > 8 then
			table.insert(out, "…")
			break
		end
		local scrubbed = Redaction.text(line)
		table.insert(out, if #scrubbed > 240 then string.sub(scrubbed, 1, 240) .. "…" else scrubbed)
	end
	return table.concat(out, "\n")
end

local ERROR_CONTEXT_FIELDS = {
	{ "Operation", "operation" }, { "Executable", "executable" }, { "Directory", "cwd" },
	{ "Root", "root" }, { "Environment", "environment" }, { "Shell", "shell" },
}

-- Copy only presentation-safe fields, never arbitrary provider details or a captured environment.
local function error_text(title: string, e): string
	local lines = { title, "Code: " .. tostring(e.code or "ERROR"), tostring(e.message or "The operation failed.") }
	local c = e.context
	if type(c) == "table" then
		for _, field in ERROR_CONTEXT_FIELDS do
			if c[field[2]] ~= nil then table.insert(lines, field[1] .. ": " .. tostring(c[field[2]])) end
		end
		if c.durationMs then table.insert(lines, "Elapsed: " .. tostring(math.floor(c.durationMs)) .. " ms") end
	end
	local details = e.details
	if type(details) == "table" then
		if type(details.field) == "string" then table.insert(lines, "Required input: " .. details.field) end
		if type(details.choices) == "table" then
			local choices = {}
			for _, choice in details.choices do
				if type(choice) == "string" then table.insert(choices, choice) end
			end
			if #choices > 0 then table.insert(lines, "Choices: " .. table.concat(choices, ", ")) end
		end
	end
	if e.detail and e.detail ~= "" then table.insert(lines, "Details:\n" .. safe_detail(tostring(e.detail))) end
	if e.nextStep and e.nextStep ~= "" then table.insert(lines, "Suggested next step (not run):\n" .. tostring(e.nextStep)) end
	return Redaction.text(table.concat(lines, "\n"))
end

-- Safe execution facts, never the child's environment or a profile's captured output.
local function error_body(e)
	local body = { ui.text(Redaction.text(e.message or "The operation failed.")) }
	local c = e.context
	if type(c) == "table" then
		local facts = {}
		for _, field in ERROR_CONTEXT_FIELDS do
			local value = c[field[2]]
			if value ~= nil then table.insert(facts, { ui.span(field[1], "muted"), ui.span(Redaction.text(value), "mono") }) end
		end
		if c.durationMs then table.insert(facts, { ui.span("Elapsed", "muted"), ui.span(tostring(math.floor(c.durationMs)) .. " ms") }) end
		table.insert(body, ui.kv(facts))
	end
	if e.detail and e.detail ~= "" then
		local detail = safe_detail(tostring(e.detail))
		if detail ~= "" then table.insert(body, ui.code(detail)) end
	end
	if e.nextStep and e.nextStep ~= "" then
		table.insert(body, hint("Suggested next step (not run):"))
		table.insert(body, ui.text(Redaction.text(e.nextStep)))
	end
	return body
end

local function error_card(title: string, e, key: string)
	local body = error_body(e)
	table.insert(body, ui.row({
		button("Copy error details", act("copy", error_text(title, e)), { variant = "quiet", icon = "copy" }),
	}))
	return with(card({ ui.span(title, "strong") }, body, {
		icon = "warn", meta = { ui.span(tostring(e.code or "ERROR"), "muted") },
	}), { key = key, tone = "error" })
end

-- Busy work, the last result, a refusal and a pending confirmation, in that order.
local function banners(s): { any }
	local out = {}
	local busy = {}
	for _, label in s.busy do
		table.insert(busy, label)
	end
	table.sort(busy)
	for i, label in busy do
		table.insert(out, with(ui.progress(nil, label), { key = "busy" .. i }))
	end
	if s.confirm then
		local c = s.confirm
		local lines = {}
		for _, line in c.lines do
			table.insert(lines, ui.text(Redaction.text(line)))
		end
		local input = table.clone(c.input or {})
		if input.root == nil then input.root = s.active_root end
		table.insert(lines, ui.code(Redaction.text(c.cmd or s.dev.describe(c.op, input)), "sh"))
		table.insert(lines, ui.row({
			button("Confirm", "confirm.yes", { variant = c.variant or "primary" }),
			button("Cancel", "confirm.no", { variant = "quiet" }),
		}))
		table.insert(out, with(card({ ui.span(c.title, "strong") }, lines, { icon = "warn" }), {
			key = "confirm",
			tone = c.tone or "warning",
		}))
	end
	if s.failure then
		local f = s.failure
		local e = f.error
		local body = error_body(e)
		local actions = {
			button("Copy error details", act("copy", error_text(f.label .. " failed", e)), { variant = "quiet", icon = "copy" }),
		}
		for i, r in f.remedies do
			table.insert(actions, button(r.label, act("remedy", tostring(i)), { variant = r.variant or "default" }))
		end
		if e.nextStep then
			table.insert(actions, button("Copy suggestion", act("copy", Redaction.text(e.nextStep)), { variant = "quiet", icon = "copy" }))
		end
		table.insert(actions, button("Dismiss", "dismiss", { variant = "quiet" }))
		table.insert(body, ui.row(actions))
		table.insert(out, with(card({ ui.span(f.label .. " failed", "strong") }, body, {
			icon = "warn",
			meta = { ui.span(e.code, "muted") },
		}), { key = "failure", tone = "error" }))
	elseif s.notice then
		local n = s.notice
		local spans = { ui.span(Redaction.text(n.text), n.tone or "success") }
		if n.sub then
			table.insert(spans, ui.span("  " .. Redaction.text(n.sub), "muted"))
		end
		table.insert(out, with(ui.row({ ui.text(spans), button("", "dismiss", { icon = "x", variant = "quiet", title = "Dismiss" }) }), {
			key = "notice",
			role = role("notice"),
		}))
	end
	return out
end

-- Screens that list a paged collection, and the top-level destination each screen belongs to.
local COLLECTION = { home = "home", worksets = "worksets", mirrors = "mirrors", prs = "prs", wis = "wis" }
local TOP = { home = "home", ws = "home", worksets = "worksets", mirrors = "mirrors", mirror = "mirrors", search = "mirrors", prs = "prs", pr = "prs", wis = "wis", wi = "wis" }
local NAV = { { "Workspaces", "home" }, { "Worksets", "worksets" }, { "Mirrors", "mirrors" }, { "PRs", "prs" }, { "Work items", "wis" } }

-- The persistent toolbar: root, reload, New, Settings; then the four top-level collections and provider sync.
local function toolbar(s)
	local entry = Store.root_entry(s, s.active_root)
	local root_label = if entry then tostring(entry.alias) else "root"
	local is_default = entry ~= nil and entry.isDefault == true
	local top = TOP[s.screen]
	local nav = {}
	for _, item in NAV do
		table.insert(nav, button(item[1], item[2], { variant = "quiet", on = top == item[2], key = "nav-" .. item[2] }))
	end
	table.insert(nav, button("", "sync.data", {
		icon = "cloud",
		variant = "quiet",
		title = "Sync providers (dev sync data): repository lists, pull requests and work items",
		key = "sync",
	}))
	local bar = with(ui.row({
		with(ui.row({
			with(ui.badge(root_label, if is_default or not entry then "accent" else "warning"), {
				actions = { click = "roots" },
				title = "dev root: "
					.. tostring(s.active_root or "?")
					.. (if is_default then " (default)" elseif entry then " (not the default)" else "")
					.. "\nClick to choose another root",
				key = "root",
			}),
		}), { role = role("title") }),
		with(ui.row({
			button("", "refresh", { icon = "refresh", variant = "quiet", title = "Reload from dev", busy = s.loading, key = "reload" }),
			button("New", if s.screen == "worksets" then "workset.new" else "create", { icon = "plus", variant = "primary", title = if s.screen == "worksets" then "New workset" else "New workspace", key = "new" }),
			button("", "settings", { icon = "sliders", variant = "quiet", title = "dev settings", key = "settings" }),
		}), { role = role("tools") }),
	}), { role = role("bar"), key = "bar" })
	return with(ui.col({ bar, with(ui.row(nav), { role = role("nav"), key = "nav" }) }), { role = role("header"), key = "header" })
end

local DETAIL_BACK = { ws = "home", mirror = "mirrors", search = "mirrors", pr = "back", wi = "back", roots = "home" }
local DETAIL_TITLE = { pr = "Pull request", wi = "Work item", search = "Search mirrors", roots = "Dev roots" }

-- A fixed back row for every screen that is not one of the four collections.
local function crumb(s, title: string)
	return with(ui.row({
		button("←", DETAIL_BACK[s.screen] or "home", { variant = "quiet", title = "Back", key = "back" }),
		with(ui.text(ui.span(bounded(title, MAX_NAME + 8), "strong")), { role = role("crumb-title") }),
	}), { role = role("crumb"), key = "crumb" })
end

local function section(title: string, count: number?, tail, count_text: string?)
	local spans = { ui.span(string.upper(title), "muted strong") }
	if count_text or count then
		table.insert(spans, ui.span("  " .. (count_text or tostring(count)), "muted"))
	end
	local kids = { ui.text(spans) }
	if tail then
		table.insert(kids, tail)
	end
	return with(ui.row(kids), { role = role("section"), key = "sec-" .. title })
end

local function lower(value: any): string
	return string.lower(tostring(value or ""))
end

-- Lowercased scalar fields of `t`: the searchable metadata of an item.
local function scalars(t, out: { string })
	if type(t) ~= "table" then return end
	for _, v in t do
		local kind = type(v)
		if kind == "string" or kind == "number" then table.insert(out, lower(v)) end
	end
end

-- Everything loaded about a workspace: its own fields, health, mounts (path, revision, branch) and extra folders.
local function workspace_text(s, w): string
	local out = {}
	scalars(w, out)
	table.insert(out, lower((Store.health(s, w))))
	local st = s.status[w.name]
	local mounts = if st and type(st.data) == "table" and type(st.data.mounts) == "table" then st.data.mounts else {}
	for _, m in mounts do
		scalars(m, out)
		if type(m.desired) == "table" then
			scalars(m.desired, out)
			scalars(m.desired.revision, out)
		end
		if type(m.observed) == "table" then scalars(m.observed.currentRevision, out) end
	end
	for _, f in (s.folders[w.name] or {}) do
		table.insert(out, lower(f.name))
	end
	return table.concat(out, "\n")
end

local function pr_text(pr): string
	local out = {}
	for _, v in { pr.title, pr.id, pr.repository, pr.project, pr.author, pr.sourceBranch, pr.targetBranch, pr.status } do
		table.insert(out, lower(v))
	end
	return table.concat(out, "\n")
end

local function wi_text(w): string
	local out = {}
	for _, v in { w.id, w.title, w.type, w.state, w.assignedTo } do
		if v ~= tern.json.null then table.insert(out, lower(v)) end
	end
	return table.concat(out, "\n")
end

-- Parse an ISO-8601 timestamp without relying on local timezone or accepting provider sentinels.
local function timestamp(value): number?
	if type(value) ~= "string" then return nil end
	local y, m, d, h, minute, second, tail = string.match(value,
		"^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
	if not y then return nil end
	local zone = string.match(tail, "^([Zz])$")
	if not zone then zone = string.match(tail, "^([+-]%d%d:%d%d)$") end
	if not zone then
		local fraction = string.match(tail, "^%.%d+([Zz])$")
		if not fraction then fraction = string.match(tail, "^%.%d+([+-]%d%d:%d%d)$") end
		zone = fraction
	end
	if not zone then return nil end
	y, m, d, h, minute, second = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(minute), tonumber(second)
	if y == 1 or y < 1970 or m < 1 or m > 12 or h > 23 or minute > 59 or second > 59 then return nil end
	local month_days = { 31, if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if d < 1 or d > month_days[m] then return nil end
	local year = y - (if m <= 2 then 1 else 0)
	local era = math.floor(year / 400)
	local yoe = year - era * 400
	local shifted_month = m + (if m > 2 then -3 else 9)
	local doy = math.floor((153 * shifted_month + 2) / 5) + d - 1
	local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
	local offset = 0
	if string.upper(zone) ~= "Z" then
		local sign, zh, zm = string.match(zone, "^([+-])(%d%d):(%d%d)$")
		if not sign or tonumber(zh) > 23 or tonumber(zm) > 59 then return nil end
		offset = (tonumber(zh) * 60 + tonumber(zm)) * 60 * (if sign == "+" then 1 else -1)
	end
	return days * 86400 + h * 3600 + minute * 60 + second - offset
end

local function age(value): string?
	local then_at = timestamp(value)
	if not then_at then return nil end
	local seconds = math.max(0, os.time() - then_at)
	if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m" end
	if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h" end
	if seconds < 604800 then return tostring(math.floor(seconds / 86400)) .. "d" end
	return tostring(math.floor(seconds / 604800)) .. "w"
end

local function pr_dates(pr)
	local items = {}
	for _, field in { { "Created", pr.createdAt }, { "Updated", pr.updatedAt } } do
		local relative = age(field[2])
		if relative then
			table.insert(items, field[1] .. " " .. relative)
		elseif field[1] == "Updated" then
			table.insert(items, "Updated not reported")
		end
	end
	return table.concat(items, " · ")
end

local function pr_date_facts(pr)
	local items = {}
	for _, field in { { "Created", pr.createdAt }, { "Updated", pr.updatedAt } } do
		if age(field[2]) then
			table.insert(items, { field[1], field[2] })
		elseif field[1] == "Updated" then
			table.insert(items, { "Updated", "Not reported" })
		end
	end
	return items
end


local function mirror_text(m): string
	local out = {}
	for _, v in { m.name, m.branch, m.path } do
		table.insert(out, lower(v))
	end
	return table.concat(out, "\n")
end

local function by_name(a, b): boolean
	local x, y = lower(a.name), lower(b.name)
	if x ~= y then return x < y end
	return tostring(a.name) < tostring(b.name)
end

-- Every loaded item of `collection` ("home" workspaces, "mirrors", "prs", "wis") whose metadata contains every
-- word of `s.filter`. Pure: runs over the whole inventory, before and independent of presentation paging.
function View.filtered(s, collection: string): { any }
	local source, text
	if collection == "home" or collection == "workspaces" then
		source = table.clone(s.workspaces)
		-- Workspaces this window observes in a tab come first; each group keeps the alphabetic order, and health
		-- never reorders rows. Grouping happens before filtering and paging so keyboard order is the visual order.
		local seen = Store.presence_map(s)
		local function open(w): boolean return seen[Store.norm(w.path)] ~= nil end
		table.sort(source, function(a, b)
			local x, y = open(a), open(b)
			if x ~= y then return x end
			return by_name(a, b)
		end)
		text = function(w) return workspace_text(s, w) end
	elseif collection == "worksets" then
		source = table.clone(s.worksets or {})
		table.sort(source, by_name)
		text = function(w) return string.lower(tostring(w.name) .. " " .. tostring(w.description or "")) end
	elseif collection == "mirrors" then
		source = table.clone(s.mirrors)
		table.sort(source, by_name)
		text = mirror_text
	elseif collection == "prs" then
		source, text = table.clone(s.prs or {}), pr_text
	elseif collection == "wis" then
		source, text = table.clone(s.wis or {}), wi_text
	else
		return {}
	end
	local words = {}
	for word in string.gmatch(lower(s.filter), "%S+") do
		table.insert(words, word)
	end
	if #words == 0 then
		return source
	end
	local out = {}
	for _, item in source do
		local hay = text(item)
		local all = true
		for _, word in words do
			if not string.find(hay, word, 1, true) then
				all = false
				break
			end
		end
		if all then table.insert(out, item) end
	end
	return out
end

-- The page on screen: `rows` (at most PAGE of the filtered items), its number clamped into range, the page count,
-- the matches (`total`) and the whole collection (`of`).
function View.page(s, collection: string)
	local key = if collection == "workspaces" then "home" else collection
	local all = View.filtered(s, key)
	local pages = math.max(1, math.ceil(#all / PAGE))
	local want = math.floor(tonumber((s.pages or {})[key]) or 1)
	local n = math.clamp(want, 1, pages)
	local first, last = (n - 1) * PAGE + 1, math.min(#all, n * PAGE)
	local of = if key == "home" then #s.workspaces elseif key == "mirrors" then #s.mirrors else #(s[key] or {})
	return { rows = table.move(all, first, last, 1, {}), page = n, pages = pages, total = #all, of = of, first = first, last = last }
end

-- Names of the workspace rows on screen, top to bottom (what the arrow keys walk).
function View.order(s): { string }
	local out = {}
	for _, w in View.page(s, "home").rows do
		table.insert(out, w.name)
	end
	return out
end

local function pager(collection: string, p)
	if p.pages <= 1 then return nil end
	return with(ui.row({
		button("‹ Prev", act("page", collection .. ":" .. tostring(p.page - 1)), {
			variant = "quiet",
			disabled = if p.page <= 1 then "This is the first page" else nil,
		}),
		with(ui.text(ui.span(string.format("%d–%d of %d · page %d/%d", p.first, p.last, p.total, p.page, p.pages), "muted")), { role = role("pager-count") }),
		button("Next ›", act("page", collection .. ":" .. tostring(p.page + 1)), {
			variant = "quiet",
			disabled = if p.page >= p.pages then "This is the last page" else nil,
		}),
	}), { role = role("pager"), key = "pager-" .. collection })
end

-- Collection title with its truthful count: matches of everything loaded while a filter is typed.
local function collection_head(title: string, p, tail)
	local count = if p.total ~= p.of then string.format("%d of %d", p.total, p.of) else tostring(p.of)
	return section(title, nil, tail, count)
end

local function tab_count(n: number): string
	return string.format("%d %s", n, if n == 1 then "tab" else "tabs")
end

-- What the window's last snapshot says about `w`. Only a positive entry is a claim; every other state is
-- "not observed" or "unknown" because the snapshot covers one native window, never every Tern window.
local function presence_text(s, w): string
	local entry = Store.presence_for(s, w)
	if entry then
		local lines = { "Open in Tern · " .. tab_count(entry.count) }
		for i, d in entry.destinations do
			if i > 8 then
				table.insert(lines, string.format("… and %d more", #entry.destinations - 8))
				break
			end
			table.insert(lines, string.format("• %s › %s", tostring(d.session_name), tostring(d.tab_name)))
		end
		table.insert(lines, "Click the icon to choose a tab or session")
		return table.concat(lines, "\n")
	elseif type(s.presence) == "table" and s.presence.available == true then
		return "Not observed in this window's sessions (other windows are not checked)"
	end
	return "Open tabs unknown: the window has not reported its sessions"
end

local function workspace_row(s, w)
	local label, tone = Store.health(s, w)
	local mounts = tonumber(w.mountCount) or 0
	local sub = mounts .. (if mounts == 1 then " mount" else " mounts")
	if w.description and w.description ~= "" then
		sub ..= " · " .. bounded((string.gsub(tostring(w.description), "%s+", " ")), MAX_DESC)
	end
	local active = s.active_ws == w.name
	local cursor = s.cursor == w.name
	local mark = if cursor and active then "ws-cursor-active" elseif cursor then "ws-cursor" elseif active then "ws-active" else "ws"
	local entry = Store.presence_for(s, w)
	local title = { with(ui.text(ui.span(tostring(w.name), "strong")), { role = role("ws-name") }) }
	if entry then
		table.insert(title, with(button(if entry.count > 1 then tostring(entry.count) else "", act("presence", w.name), {
			icon = "layers",
			variant = "quiet",
			title = presence_text(s, w),
			key = "presence:" .. w.name,
		}), { role = role("ws-presence") }))
	else
		table.insert(title, with(button("?", act("presence", w.name), {
			variant = "quiet",
			title = presence_text(s, w),
			key = "presence:" .. w.name,
		}), { role = role("ws-presence-unknown") }))
	end
	local top = { with(ui.row(title), { role = role("ws-title") }), ui.badge(label, tone) }
	return with(ui.col({
		with(ui.row(top), { role = role("ws-top") }),
		with(ui.text(ui.span(sub, "muted")), { role = role("ws-sub") }),
	}), {
		key = "ws:" .. w.name,
		role = role(mark),
		title = tostring(w.name)
			.. "\n"
			.. tostring(w.path)
			.. "\n"
			.. presence_text(s, w)
			.. (if active then "\nThe focused pane is in this workspace" else "")
			.. "\nClick to inspect",
		actions = { click = act("ws", w.name) },
	})
end

-- A mirror: status and drift on the row, Browse (its real checked-out tree) apart from Git and sync.
local function mirror_row(m)
	local name = tostring(m.name)
	local browse = button("Browse", act("mirror.browse", name), { icon = "folder", variant = "quiet", title = "Browse the checked-out files in " .. tostring(m.path) })
	if m.linked == false then
		return with(ui.col({
			with(ui.row({
				with(ui.text(ui.span(name, "strong")), { role = role("mirror-main") }),
				ui.badge("unlinked", "error"),
			}), { role = role("mirror-top") }),
			with(ui.row({
				with(ui.text(ui.span("repository data missing; dev cannot sync it", "muted")), { role = role("mirror-main") }),
				with(ui.row({ browse }), { role = role("tools") }),
			}), { role = role("mirror-sub") }),
		}), {
			key = "mirror:" .. name,
			role = role("mirror"),
			title = tostring(m.path)
				.. "\nIts repository under .dev/repos is gone. Files are untouched: copy what you need, move the folder aside, then dev mirror add <repository>.",
		})
	end
	local tone = if m.isClean then "success" else "warning"
	local status = if m.isClean then "clean" else "edited"
	local ahead, behind = tonumber(m.ahead) or 0, tonumber(m.behind) or 0
	local drift = {}
	if ahead > 0 then
		table.insert(drift, "↑" .. ahead)
	end
	if behind > 0 then
		table.insert(drift, "↓" .. behind)
	end
	return with(ui.col({
		with(ui.row({
			with(ui.text(ui.span(name, "strong")), { role = role("mirror-main") }),
			ui.badge(status, tone),
		}), { role = role("mirror-top") }),
		with(ui.row({
			with(ui.text({
				ui.span(tostring(m.branch or "?"), "mono muted"),
				ui.span(if #drift > 0 then "  " .. table.concat(drift, " ") else "", "muted"),
			}), { role = role("mirror-main") }),
			with(ui.row({
				browse,
				button("", act("git", tostring(m.path)), { icon = "git-branch", variant = "quiet", title = "Open Git for this mirror" }),
				button("", act("mirror.sync", name), { icon = "refresh", variant = "quiet", title = "Sync this mirror (keeps local edits)" }),
			}), { role = role("tools") }),
		}), { role = role("mirror-sub") }),
	}), { key = "mirror:" .. name, role = role("mirror"), title = tostring(m.path) })
end

local function problem(s)
	local e = s.load_error
	local body = error_body(e)
	table.insert(body, ui.row({ button("Settings", "settings", { icon = "sliders", variant = "quiet" }) }))
	table.insert(body, ui.row({ button("Reload", "refresh", { variant = "primary" }) }))
	return with(card({ ui.span("dev is not answering", "strong") }, body, { icon = "warn", meta = { ui.span(e.code, "muted") } }), {
		key = "problem",
		tone = "error",
	})
end

local function worksets(s)
	local p = View.page(s, "worksets")
	local kids = { collection_head("Worksets", p, button("", "worksets.refresh", { icon = "refresh", variant = "quiet", title = "Reload worksets", busy = s.busy.worksets ~= nil })) }
	table.insert(kids, hint("Saved workspace recipes. Editing a recipe does not change existing workspaces."))
	if s.worksets_error then
		table.insert(kids, error_card("Could not read worksets", s.worksets_error, "worksets-error"))
		if s.worksets then table.insert(kids, hint("Showing the last successful list, not current observations.")) end
	end
	if s.worksets == nil and s.busy.worksets then
		table.insert(kids, ui.progress(nil, "Reading worksets…"))
	elseif p.of == 0 then
		table.insert(kids, hint("No worksets saved in this root. New saves a recipe from repositories or labels; no provider is required."))
	elseif p.total == 0 then
		table.insert(kids, hint("No matching worksets. Clear the search to see every recipe."))
	end
	for _, w in p.rows do
		local name = tostring(w.name)
		table.insert(kids, with(ui.col({
			with(ui.row({
				button(bounded(name, MAX_NAME), act("workset.edit", name), { variant = "quiet", title = "Edit " .. name, size = "md" }),
				ui.badge(tostring(w.memberCount or 0) .. " members", "muted"),
				button("Create workspace", act("workset.create", name), { variant = "quiet", title = "Start from " .. name }),
			}), { role = role("workset-top") }),
			hint(bounded(tostring(w.description or ""), MAX_DESC)),
		}), { key = "workset:" .. name, role = role("workset") }))
	end
	local controls = pager("worksets", p)
	if controls then table.insert(kids, controls) end
	return kids
end

local function home(s)
	local kids = {}
	if s.load_error then
		table.insert(kids, problem(s))
		if #s.workspaces == 0 then return kids end
	end
	if s.workspaces_stale then table.insert(kids, hint("Showing the last successful workspace list. It is stale until a refresh succeeds.")) end
	local p = View.page(s, "home")
	table.insert(kids, collection_head("Workspaces", p, nil))
	if s.loading and #s.workspaces == 0 then
		table.insert(kids, ui.progress(nil, "Reading workspaces…"))
	elseif p.total == 0 then
		table.insert(kids, hint(if #s.workspaces == 0 then "No workspaces yet. Choose New to create one." else "No workspace matches the filter."))
	end
	if #p.rows > 0 then
		local rows = {}
		local open_rows = 0
		for _, w in p.rows do
			if Store.presence_for(s, w) then open_rows += 1 end
		end
		-- Headings only when they separate something: this page holds observed rows, or continues past them.
		local grouped = open_rows > 0 or (p.page > 1 and next(Store.presence_map(s)) ~= nil)
		local last_group = nil
		for _, w in p.rows do
			if grouped then
				local group = if Store.presence_for(s, w) then "open" else "other"
				if group ~= last_group then
					last_group = group
					table.insert(rows, with(ui.text(ui.span(if group == "open" then "Open in Tern" else "Other workspaces", "muted")), {
						role = role("ws-group"),
						key = "ws-group:" .. group,
					}))
				end
			end
			table.insert(rows, workspace_row(s, w))
		end
		table.insert(kids, with(ui.col(rows), { key = "ws-list", role = role("list") }))
	end
	local pg = pager("home", p)
	if pg then table.insert(kids, pg) end
	return kids
end

local ACTION_TEXT = {
	create = { "create", "accent" },
	checkout = { "checkout", "accent" },
	fast_forward = { "fast-forward", "accent" },
	rebase = { "rebase", "warning" },
	up_to_date = { "up to date", "success" },
	skipped = { "skip", "warning" },
}

local REASON_TEXT = {
	dirty_worktree = "uncommitted changes",
	ahead_commits = "local commits not pushed",
	diverged_history = "diverged from remote",
	not_a_worktree = "folder is not a worktree",
	no_local_mirror = "no local mirror",
	readonly = "read-only mount",
	not_tracking_branch = "not tracking a branch",
}

local function plural(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

-- A folder dev does not track: what it is and whether it holds work that exists nowhere else (`risk`).
local function folder_detail(f): (string, boolean)
	if not f.git then
		return "plain folder · not in ws.md", false
	end
	local r = f.repo
	if not r then
		return "git repository · not in ws.md", false
	end
	local parts = {}
	if not r.commits then
		table.insert(parts, "nothing committed")
	elseif not r.remote then
		table.insert(parts, "local only, no remote")
	elseif not r.upstream then
		table.insert(parts, (if r.branch then "branch " .. r.branch else "detached HEAD") .. " not pushed")
	elseif (r.ahead or 0) > 0 then
		table.insert(parts, plural(r.ahead, "commit", "commits") .. " not pushed")
	end
	if r.changes > 0 then
		table.insert(parts, plural(r.changes, "uncommitted change", "uncommitted changes"))
	end
	if #parts == 0 then
		return "git repository · nothing unpushed · not in ws.md", false
	end
	return "git repository · " .. table.concat(parts, " · "), true
end

local function plan_card(s)
	local p = s.plan
	local data = p.data or {}
	local rows = {}
	local dirty, diverged, changes = false, false, 0
	for _, m in (data.mounts or {}) do
		local a = ACTION_TEXT[m.action] or { tostring(m.action), "muted" }
		local spans = { ui.span(tostring(m.path), "strong") }
		if m.action == "skipped" and m.reason then
			table.insert(spans, ui.span("  " .. (REASON_TEXT[m.reason] or tostring(m.reason)), "muted"))
		end
		if m.reason == "dirty_worktree" then
			dirty = true
		elseif m.reason == "diverged_history" then
			diverged = true
		end
		if m.action ~= "up_to_date" and m.action ~= "skipped" then
			changes += 1
		end
		table.insert(rows, with(ui.row({ ui.text(spans), ui.badge(a[1], a[2]) }), { key = "plan:" .. tostring(m.path), role = role("plan-row") }))
	end
	local sum = data.summary or {}
	local skipped = tonumber(sum.skipped) or 0
	if #rows == 0 then
		table.insert(rows, ui.text("ws.md lists no repositories yet, so there is nothing to update."))
		local extra = s.folders[p.ws] or {}
		if #extra > 0 then
			table.insert(rows, hint("This workspace still holds folders ws.md does not list; dev leaves them alone:"))
			for _, f in extra do
				local detail, risk = folder_detail(f)
				local spans = { ui.span(f.name, "strong"), ui.span("  " .. detail, if risk then "warning" else "muted") }
				table.insert(rows, with(ui.text(spans), { key = "plan-folder:" .. f.name, role = role("plan-row") }))
			end
		end
	elseif changes == 0 then
		table.insert(rows, hint(if skipped > 0 then "Nothing would change: the skipped mounts need attention first." else "Everything already matches ws.md."))
	end
	local actions = {}
	if changes > 0 then
		table.insert(rows, ui.code(s.dev.describe("update", { ws = p.ws }), "sh"))
		table.insert(actions, button("Apply", "apply", { variant = "primary" }))
	elseif #(data.mounts or {}) == 0 then
		table.insert(actions, button("Add repo", act("add", p.ws), { variant = "primary", icon = "plus" }))
	end
	if dirty then
		table.insert(rows, hint("--autostash stashes uncommitted changes, fast-forwards, then applies them back; the stash stays as a backup."))
		table.insert(actions, button("Apply with --autostash", act("apply", "autostash")))
	end
	if diverged then
		table.insert(rows, hint("--rebase rebases diverged mounts onto the remote branch and aborts on conflict."))
		table.insert(actions, button("Apply with --rebase", act("apply", "rebase")))
	end
	table.insert(actions, button("Close", "plan.close", { variant = "quiet" }))
	table.insert(rows, ui.row(actions))
	return with(card({ ui.span("Update plan", "strong") }, rows, {
		icon = "download",
		meta = {
			ui.span(string.format("%d to change · %d up to date · %d skipped", changes, tonumber(sum.upToDate) or 0, skipped), "muted"),
		},
	}), { key = "plan" })
end

local STATE_TONE = {
	clean = "success",
	dirty = "warning",
	missing = "error",
	wrong_revision = "warning",
	ahead = "info",
	behind = "info",
	diverged = "error",
}

local function revision_text(desired): (string, string)
	local r = (desired or {}).revision or {}
	local mode = tostring(r.mode or "?")
	if mode == "track" then
		return "track", tostring(r.branch or "?")
	elseif r.tag then
		return mode, tostring(r.tag)
	elseif r.commit then
		return mode, short_sha(r.commit)
	end
	return mode, ""
end

local function mount_card(ws: string, m, stale: boolean?)
	local o = m.observed or {}
	local mode, target = revision_text(m.desired)
	local cur = o.currentRevision or {}
	local where = tostring(cur.branch or "") .. (if cur.commitSha then " @ " .. short_sha(cur.commitSha) else "")
	local facts = {}
	if (tonumber(o.aheadCount) or 0) > 0 then
		table.insert(facts, "↑" .. o.aheadCount)
	end
	if (tonumber(o.behindCount) or 0) > 0 then
		table.insert(facts, "↓" .. o.behindCount)
	end
	if (tonumber(o.modifiedFiles) or 0) > 0 then
		table.insert(facts, o.modifiedFiles .. " modified")
	end
	if (tonumber(o.untrackedFiles) or 0) > 0 then
		table.insert(facts, o.untrackedFiles .. " untracked")
	end
	local state = tostring(m.state or "?")
	local body = {
		ui.row({
			ui.badge((if stale then "last read: " else "") .. state, if stale then "muted" else STATE_TONE[state] or "muted"),
			ui.text({ ui.span(where, "mono"), ui.span(if #facts > 0 then "  " .. table.concat(facts, " · ") else "", "muted") }),
		}),
	}
	for _, msg in (m.messages or {}) do
		table.insert(body, hint(tostring(msg)))
	end
	local pair = ws .. "|" .. tostring(m.path)
	local tools = {}
	local blocked = if stale then "Refresh the workspace status before changing this mount" else nil
	if o.exists and o.path then
		table.insert(tools, button("Git", act("git", o.path), { icon = "git-branch" }))
		table.insert(tools, button("", act("copy", o.path), { icon = "copy", variant = "quiet", title = "Copy path" }))
	end
	if mode == "track" then
		table.insert(tools, button("Lock", act("lock", pair), { title = "Freeze this mount at its current commit", disabled = blocked }))
	else
		table.insert(tools, button("Unlock", act("unlock", pair), { title = "Track a branch again", disabled = blocked }))
	end
	table.insert(tools, button("Track…", act("track", pair), { title = "dev ws track: check out and follow another branch", disabled = blocked }))
	table.insert(tools, button("Tag…", act("tag", pair), { title = "dev ws tag: pin this mount to a tag", disabled = blocked }))
	table.insert(tools, button("", act("remove", pair), { icon = "trash", variant = "quiet", title = "Remove mount…", disabled = blocked }))
	table.insert(body, ui.row(tools))
	return with(card({ ui.span(tostring(m.path), "strong") }, body, {
		icon = "folder",
		meta = { ui.span(mode .. (if target ~= "" then " " .. target else ""), "muted") },
	}), { key = "mount:" .. tostring(m.path), role = role("mount") })
end

local function reason(e): string
	if type(e) == "table" then
		return Redaction.text(e.message or e.code or "unknown error")
	end
	return Redaction.text(e or "unknown error")
end

local function stamp(t: any): string?
	if type(t) == "number" then
		return os.date("%Y-%m-%d %H:%M", t)
	end
	return nil
end

-- The folder tree of `files` (`{ root, open, dirs }`): only folders a person opened are drawn, each read lazily by
-- the data layer. Folders toggle, files open.
local function file_tree(files)
	local dirs, openset = files.dirs or {}, files.open or {}
	local function level(dir: string): { any }
		local d = dirs[dir]
		if d == nil then
			return { ui.progress(nil, "Reading folder…") }
		end
		-- `d.entries` is only the page on screen (the sorted listing sliced by the data layer); `d.offset` is its start.
		local entries = d.entries or {}
		local out = {}
		if d.error then
			table.insert(out, hint("Could not read this folder: " .. reason(d.error)))
		end
		local total = math.max(tonumber(d.total) or 0, #entries)
		if total == 0 then
			if not d.error then table.insert(out, if d.loading then ui.progress(nil, "Reading folder…") else hint("Empty folder.")) end
			return out
		end
		local offset = math.max(tonumber(d.offset) or 0, 0)
		local pages = math.ceil(total / DIR_PAGE)
		local page = math.clamp(math.floor(offset / DIR_PAGE) + 1, 1, pages)
		local function dir_pager(where: string)
			if pages <= 1 then return end
			table.insert(out, with(ui.row({
				button("‹ Prev", act("files.page", dir .. ":" .. tostring(page - 1)), { variant = "quiet", busy = d.loading, disabled = if page <= 1 then "This is the first page" else nil }),
				with(ui.text(ui.span(string.format("%d–%d of %d", offset + 1, offset + #entries, total), "muted")), { role = role("pager-count") }),
				button("Next ›", act("files.page", dir .. ":" .. tostring(page + 1)), { variant = "quiet", busy = d.loading, disabled = if page >= pages then "This is the last page" else nil }),
			}), { key = "pager:" .. where .. ":" .. dir, role = role("pager") }))
		end
		dir_pager("top")
		if d.loading then
			table.insert(out, ui.progress(nil, "Reading this folder…"))
		end
		for _, e in entries do
			local path = tostring(e.path)
			local when = stamp(e.modifiedAt)
			local note = if e.broken then "\nBroken link: its target is gone" elseif e.link then "\nSymbolic link" else ""
			local mark = if e.link then " ↗" else ""
			if e.directory then
				local opened = openset[path] == true
				table.insert(out, with(ui.row({
					with(ui.text(ui.span(if opened then "▾" else "▸", "muted")), { role = role("chev") }),
					with(ui.text({ ui.span(tostring(e.name), "mono strong"), ui.span(mark, "muted") }), { role = role("file-name") }),
				}), {
					key = "dir:" .. path,
					role = role("dir"),
					title = path .. note .. (if when then "\nModified " .. when else ""),
					actions = { click = act("files.toggle", path) },
				}))
				if opened then
					table.insert(out, with(ui.col(level(path)), { key = "kids:" .. path, role = role("tree-kids") }))
				end
			else
				local props = {
					key = "file:" .. path,
					role = role("file"),
					title = path .. note .. (if when then "\nModified " .. when else "") .. (if e.broken then "" else "\nClick to open in the editor"),
				}
				if not e.broken then props.actions = { click = act("files.open", path) } end
				table.insert(out, with(ui.row({
					with(ui.text(ui.span("", "muted")), { role = role("chev") }),
					with(ui.text({ ui.span(tostring(e.name), if e.broken then "mono muted" else "mono"), ui.span(if e.broken then " (broken link)" else mark, "muted") }), { role = role("file-name") }),
				}), props))
			end
		end
		dir_pager("bottom")
		return out
	end
	return with(ui.col(level(files.root)), { key = "tree", role = role("tree") })
end

-- Repository commit timestamps are useful context; workspace creation and ws.md metadata are not an activity feed.
local function activity_section(files)
	local rows = {}
	for i, item in (files and files.activity) or {} do
		if item.kind == "commit" then
			local path = tostring(item.path)
			table.insert(rows, with(ui.row({
				ui.text(ui.span(tostring(item.name))),
				ui.text(ui.span(stamp(item.modifiedAt) or "time unknown", "muted")),
			}), { key = "commit:" .. i .. ":" .. path, role = role("plan-row"), title = path }))
		end
	end
	if #rows == 0 then return nil end
	return { section("Repository activity", nil, nil), with(ui.col(rows), { key = "repository-activity", role = role("list") }) }
end

-- ws.md's body as Markdown, without the YAML front matter (its description and mounts are shown elsewhere).
local function strip_frontmatter(text: string): string
	local t = string.gsub(text, "^\239\187\191", "")
	local rest = string.match(t, "^%-%-%-[ \t]*\r?\n(.*)$")
	if rest then
		local after = string.match(rest, "^%-%-%-[ \t]*\r?\n(.*)$")
		if after then return after end
		if string.match(rest, "^%-%-%-[ \t]*$") then return "" end
		after = string.match(rest, "^.-\r?\n%-%-%-[ \t]*\r?\n(.*)$")
		if after then return after end
		if string.match(rest, "^.-\r?\n%-%-%-[ \t]*$") then return "" end
	end
	return t
end

local WS_TABS = { { "overview", "Overview" }, { "repositories", "Repositories" }, { "files", "Files" } }

local function workspace_tab(s, name: string): string
	local tab = (s.workspace_tabs or {})[name]
	for _, t in WS_TABS do
		if t[1] == tab then return tab end
	end
	return "overview"
end

-- The persistent action bar and tab strip of the selected workspace; the render keeps them outside the scrolling body.
local function workspace_chrome(s): { any }
	local w = Store.workspace(s, s.selected)
	if not w then return {} end
	local empty = (tonumber(w.mountCount) or 0) == 0
	local active = workspace_tab(s, w.name)
	local tabs = {}
	for _, t in WS_TABS do
		table.insert(tabs, button(t[2], act("ws.tab", t[1]), { variant = "quiet", on = active == t[1], key = "tab-" .. t[1] }))
	end
	return {
		with(ui.row({
			button("Open in session…", act("open", w.name), { variant = "primary", icon = "open", title = "Choose the Tern session for this workspace, or start a new one" }),
			button("Start OMP", act("start", w.name), { icon = "play", title = "dev ws start: start or focus OMP in HerdR" }),
			button("Update…", act("update", w.name), {
				icon = "download",
				title = "Plan first (dev ws update --dry-run), then apply",
				disabled = if empty then "ws.md lists no repositories to update" else nil,
			}),
			button("Add repo", act("add", w.name), { icon = "plus" }),
			button("Check remotes", act("check", w.name), {
				icon = "cloud",
				title = "dev ws status --refresh: fetch the remotes, then compare (slow)",
				disabled = if empty then "ws.md lists no repositories" else nil,
			}),
		}), { role = role("workspace-actions"), key = "workspace-actions" }),
		with(ui.row(tabs), { role = role("workspace-tabs"), key = "workspace-tabs" }),
	}
end

-- Full Markdown context is the last section of Overview, never mixed with repository or file navigation.
local function notes_section(files, name: string)
	local head = section("Workspace notes", nil, button("Edit", act("manifest", name), { icon = "pencil", variant = "quiet", title = "Edit ws.md" }))
	local manifest = files and files.manifest
	if manifest == nil then
		return { head, ui.progress(nil, "Reading ws.md…") }
	end
	if manifest.error then
		return { head, hint("ws.md could not be read: " .. reason(manifest.error)) }
	end
	local body = string.gsub(strip_frontmatter(tostring(manifest.text or "")), "^%s+", "")
	body = string.gsub(body, "%s+$", "")
	local out = { head }
	if body == "" then
		table.insert(out, hint("ws.md has no notes beyond its repository list."))
	else
		table.insert(out, with(ui.col({ ui.md(Redaction.text(body)) }), { key = "notes", role = role("notes") }))
	end
	local when = stamp(manifest.modifiedAt)
	if when then table.insert(out, hint("ws.md modified " .. when)) end
	return out
end

local function workspace(s)
	local w = Store.workspace(s, s.selected)
	if not w then
		return { hint("This workspace is gone. Go back and reload.") }
	end
	local files = (s.files or {})[w.name]
	local label, tone = Store.health(s, w)
	local empty = (tonumber(w.mountCount) or 0) == 0
	local tab = workspace_tab(s, w.name)
	local st = s.status[w.name]
	local stale = st ~= nil and (st.stale or st.loading or st.error ~= nil) or s.workspaces_stale
	local checked = s.checked[w.name]
	local kids = {}
	-- The result of Update… is shown on every tab so it is never lost behind another one.
	if s.plan and s.plan.ws == w.name then
		table.insert(kids, plan_card(s))
	end

	if tab == "files" then
		if files and files.root then
			table.insert(kids, file_tree(files))
		else
			table.insert(kids, ui.progress(nil, "Reading files…"))
		end
		return kids
	end

	if tab == "repositories" then
		local can_remove = not empty and st and not stale and type(st.data) == "table" and #(st.data.mounts or {}) > 0
		table.insert(kids, section("Repositories", tonumber(w.mountCount) or 0, if can_remove
			then button("Remove all…", act("remove.all", w.name), { icon = "trash", variant = "quiet", title = "Remove every mount, one at a time; stops at the first refusal" })
			else nil))
		if empty then
			table.insert(kids, hint("No repositories in ws.md yet. Add one to start working."))
		else
			if st and st.error then table.insert(kids, error_card("Status unavailable", st.error, "status-error")) end
			if st and st.data then
				if stale then
					table.insert(kids, hint("Showing stale mount observations" .. (if checked then " from " .. os.date("%H:%M:%S", checked) else "") .. ". Refresh status before changing mounts."))
				end
				if st.loading then table.insert(kids, ui.progress(nil, "Refreshing mount status…")) end
				local cards = {}
				for _, m in st.data.mounts or {} do table.insert(cards, mount_card(w.name, m, stale)) end
				table.insert(kids, with(ui.col(cards), { key = "mounts", role = role("list") }))
			elseif not st or st.loading then
				table.insert(kids, ui.progress(nil, "Reading mount status…"))
			end
		end
		local extra = s.folders[w.name] or {}
		if #extra > 0 then
			table.insert(kids, section("Other folders", #extra, nil))
			local rows = {}
			for _, f in extra do
				local detail, risk = folder_detail(f)
				-- A remote URL may carry credentials (https://user:token@host/...); show it without them.
				local remote = f.repo and f.repo.remote and string.gsub(f.repo.remote, "^(%a[%w+.-]*://)[^/@]*@", "%1")
				local title = f.path .. (if remote then "\nremote: " .. remote else "")
				table.insert(rows, with(ui.row({
					with(ui.col({
						ui.text(ui.span(f.name, "strong")),
						ui.text(ui.span(detail, if risk then "warning" else "muted")),
					}), { role = role("mirror-main") }),
					button("", act("copy", f.path), { icon = "copy", variant = "quiet", title = "Copy path" }),
				}), { key = "folder:" .. f.name, role = role("folder"), title = title }))
			end
			table.insert(kids, with(ui.col(rows), { key = "folders", role = role("list") }))
			table.insert(kids, hint("dev does not track these: update, status and remove leave them alone."))
		end
		return kids
	end

	-- Overview: identity, status facts, repository activity, then the full rendered notes.
	table.insert(kids, with(ui.row({
		with(ui.text(ui.span(tostring(w.path), "mono muted")), { role = role("path") }),
		button("", act("copy", tostring(w.path)), { icon = "copy", variant = "quiet", title = "Copy workspace path" }),
	}), { role = role("desc"), key = "path" }))
	if w.description and w.description ~= "" then
		table.insert(kids, with(ui.row({
			ui.text(ui.span(bounded(w.description, 400), "muted")),
			button("", act("describe", w.name), { icon = "pencil", variant = "quiet", title = "Edit description" }),
		}), { role = role("desc"), key = "desc" }))
	else
		table.insert(kids, with(ui.row({
			button("Add description", act("describe", w.name), { icon = "pencil", variant = "quiet" }),
		}), { role = role("desc"), key = "desc" }))
	end
	local facts_rows = {
		{ ui.span("Status", "muted"), ui.span(label, tone) },
		{ ui.span("Repositories", "muted"), ui.span(tostring(tonumber(w.mountCount) or 0)) },
	}
	if checked then table.insert(facts_rows, { ui.span("Status read", "muted"), ui.span(os.date("%Y-%m-%d %H:%M", checked)) }) end
	table.insert(kids, ui.kv(facts_rows))
	local activity = activity_section(files)
	if activity then
		for _, n in activity do table.insert(kids, n) end
	end
	for _, n in notes_section(files, w.name) do table.insert(kids, n) end
	return kids
end

-- The mirror whose checked-out tree `s.browse` shows.
local function browsed_mirror(s)
	local b = s.browse
	for _, m in s.mirrors do
		if b and b.name and m.name == b.name then return m end
	end
	for _, m in s.mirrors do
		if b and b.root and Store.norm(m.path) == Store.norm(b.root) then return m end
	end
	for _, m in s.mirrors do
		if m.name == s.selected then return m end
	end
	return nil
end

local function mirror_detail(s)
	local b = s.browse
	local m = browsed_mirror(s)
	if not b and not m then
		return { hint("This mirror is gone. Go back and reload.") }
	end
	local kids = {}
	local path = tostring((b and b.root) or (m and m.path) or "")
	if m then
		local tone = if m.linked == false then "error" elseif m.isClean then "success" else "warning"
		local status = if m.linked == false then "unlinked" elseif m.isClean then "clean" else "edited"
		local facts_rows = {
			{ ui.span("Status", "muted"), ui.span(status, tone) },
			{ ui.span("Branch", "muted"), ui.span(tostring(m.branch or "?"), "mono") },
			{ ui.span("Path", "muted"), ui.span(path, "mono") },
		}
		local ahead, behind = tonumber(m.ahead) or 0, tonumber(m.behind) or 0
		if ahead > 0 or behind > 0 then
			table.insert(facts_rows, 3, { ui.span("Drift", "muted"), ui.span("↑" .. ahead .. " ahead · ↓" .. behind .. " behind") })
		end
		table.insert(kids, ui.kv(facts_rows))
		local tools = {}
		if m.linked ~= false then
			table.insert(tools, button("Git", act("git", tostring(m.path)), { icon = "git-branch", title = "Open Git for this mirror" }))
			table.insert(tools, button("Sync", act("mirror.sync", tostring(m.name)), { icon = "refresh", title = "Sync this mirror (keeps local edits)" }))
		end
		table.insert(tools, button("", act("copy", path), { icon = "copy", variant = "quiet", title = "Copy path" }))
		table.insert(kids, with(ui.row(tools), { key = "mirror-actions", role = role("actions") }))
	end
	table.insert(kids, section("Files", nil, nil))
	if b and b.root then
		table.insert(kids, file_tree(b))
	else
		table.insert(kids, ui.progress(nil, "Reading files…"))
	end
	local activity = activity_section(b)
	if activity then
		for _, n in activity do table.insert(kids, n) end
	end
	return kids
end

local function mirrors(s)
	local p = View.page(s, "mirrors")
	local kids = {
		collection_head("Mirrors", p, ui.row({
			button("", "mirror.add", { icon = "plus", variant = "quiet", title = "Add a mirror (dev mirror add)" }),
			button("", "search", { icon = "search", variant = "quiet", title = "Search the mirrors' code (dev qmd search)" }),
			button("Sync all", act("mirror.sync", ""), { icon = "refresh", variant = "quiet", title = "Sync every mirror (keeps local edits)" }),
		})),
	}
	if s.mirrors_error then table.insert(kids, error_card("Could not refresh mirrors", s.mirrors_error, "mirrors-error")) end
	if s.mirrors_stale and #s.mirrors > 0 then table.insert(kids, hint("Showing the last successful mirror list, not current observations.")) end
	if #p.rows == 0 then
		table.insert(kids, hint(if #s.mirrors == 0 then "No mirrors in this root. Add one with the + button." else "No mirror matches the filter."))
		return kids
	end
	local rows = {}
	for _, m in p.rows do
		table.insert(rows, mirror_row(m))
	end
	table.insert(kids, with(ui.col(rows), { key = "mirror-all", role = role("list") }))
	local pg = pager("mirrors", p)
	if pg then table.insert(kids, pg) end
	return kids
end

local function prs(s)
	local p = View.page(s, "prs")
	local query = s.pr_query or {}
	local busy = s.busy.pull_requests ~= nil
	local scope = query.scope == "all" and "All PRs" or "Associated with me"
	local status = query.status or "open"
	local active = { "Showing " .. scope, status }
	for _, field in { { "repo", query.repo }, { "provider", query.provider }, { "project", query.project }, { "workspace", query.ws }, { "label", query.label } } do
		if field[2] ~= nil and field[2] ~= "" then table.insert(active, field[1] .. "=" .. tostring(field[2])) end
	end
	local controls = ui.row({
		button("Associated with me", "prs.scope=mine", { variant = "quiet", on = query.scope ~= "all", disabled = if busy then "Pull requests are loading" else nil }),
		button("All PRs", "prs.scope=all", { variant = "quiet", on = query.scope == "all", disabled = if busy then "Pull requests are loading" else nil }),
		button("Filters", "prs.filters", { icon = "filter", variant = "quiet", disabled = if busy then "Pull requests are loading" else nil }),
		button("Reset", "prs.filters.reset", { variant = "quiet", disabled = if busy then "Pull requests are loading" else nil }),
		button("Fetch live", "prs.live", { icon = "cloud", variant = "quiet", title = "Fetch pull requests from providers (network)", disabled = if busy then "Pull requests are loading" else nil }),
	})
	local kids = { collection_head("Pull requests", p, controls) }
	table.insert(active, "cached results; Fetch live refreshes providers. Text search filters loaded results only.")
	table.insert(kids, hint(table.concat(active, " · ")))
	if s.prs_error then
		table.insert(kids, error_card("Could not read pull requests", s.prs_error, "prs-error"))
		if s.prs then table.insert(kids, hint("Showing the last successful pull request list, not current observations.")) end
	end
	if s.prs_warning then
		table.insert(kids, error_card("Incomplete pull request list", s.prs_warning, "prs-warning"))
		table.insert(kids, hint("Showing pull requests from the providers that responded."))
	end
	if not s.prs then
		if not s.prs_error then table.insert(kids, hint("Reading the cache…")) end
		return kids
	end
	if #s.prs == 0 then
		table.insert(kids, hint("No pull requests to display."))
		return kids
	end
	if #p.rows == 0 then
		table.insert(kids, hint("No pull request matches the filter."))
		return kids
	end
	local rows = {}
	for i, pr in p.rows do
		local who = tostring(pr.author or "?")
		local where = tostring(pr.repository or "?") .. " · " .. tostring(pr.sourceBranch or "?") .. " → " .. tostring(pr.targetBranch or "?")
		local kidsrow = {
			ui.text({ ui.span("#" .. tostring(pr.id or "?") .. "  ", "accent"), ui.span(bounded(pr.title, 120), "strong"), ui.span(if pr.isDraft then "  draft" else "", "warning") }),
			ui.text(ui.span(where .. " · " .. who, "muted")),
		}
		local dates = pr_dates(pr)
		if dates ~= "" then
			local full = {}
			for _, field in { { "Created", pr.createdAt }, { "Updated", pr.updatedAt } } do
				if age(field[2]) then table.insert(full, field[1] .. ": " .. field[2]) end
			end
			table.insert(kidsrow, with(ui.text(ui.span(dates, "muted")), { title = table.concat(full, "\n"), role = role("pr-dates") }))
		end
		local tools = {}
		if type(pr.url) == "string" then
			table.insert(tools, button("Details", act("pr", pr.url), { icon = "info" }))
			table.insert(tools, button("Check out as workspace", act("pr.checkout", pr.url), { icon = "branch" }))
			table.insert(tools, button("", act("url", pr.url), { icon = "open", variant = "quiet", title = "Open in the browser" }))
		end
		table.insert(kidsrow, with(ui.row(tools), { role = role("actions") }))
		table.insert(rows, with(ui.col(kidsrow), {
			key = "pr:" .. tostring(pr.tenant or pr.organization or "") .. ":" .. tostring(pr.provider or "") .. ":" .. tostring(pr.project or "") .. ":" .. tostring(pr.repository or "") .. ":" .. tostring(pr.id or i),
			role = role("pr"),
		}))
	end
	table.insert(kids, with(ui.col(rows), { key = "pr-list", role = role("list") }))
	local pg = pager("prs", p)
	if pg then table.insert(kids, pg) end
	return kids
end

local function roots(s)
	local kids = { section("Dev roots", #s.roots, nil) }
	if s.roots_error then
		table.insert(kids, hint("dev roots failed: " .. tostring(s.roots_error.message)))
	end
	local active = Store.root_entry(s, s.active_root)
	local rows = {}
	for _, r in s.roots do
		local here = r == active
		local tags = {}
		if r.isDefault then
			table.insert(tags, ui.badge("default", "accent"))
		end
		if here then
			table.insert(tags, ui.badge("in use", "success"))
		end
		table.insert(rows, with(ui.col({
			with(ui.row({
				with(ui.text(ui.span(tostring(r.alias), "strong")), { role = role("ws-name") }),
				with(ui.row(tags), { role = role("tags") }),
			}), { role = role("ws-top") }),
			ui.text(ui.span(tostring(r.path), "muted")),
		}), {
			key = "root:" .. tostring(r.path),
			role = role(if here then "ws-active" else "ws"),
			title = if here then "This panel reads this root" else "Read this root instead",
			actions = { click = act("root", tostring(r.path)) },
		}))
	end
	if #rows > 0 then
		table.insert(kids, with(ui.col(rows), { key = "root-list", role = role("list") }))
	end
	table.insert(kids, hint("Applies to this plugin only (sidebar and panel); it does not run dev use. Picking the default root goes back to following dev."))
	return kids
end

-- HTML from Azure DevOps fields as plain text.
local function plain(text: any): string
	local t = tostring(text or "")
	t = string.gsub(t, "<[Bb][Rr]%s*/?>", "\n")
	t = string.gsub(t, "</?[Pp]>", "\n")
	t = string.gsub(t, "<[^>]+>", "")
	t = string.gsub(t, "&nbsp;", " ")
	t = string.gsub(t, "&lt;", "<")
	t = string.gsub(t, "&gt;", ">")
	t = string.gsub(t, "&quot;", '"')
	t = string.gsub(t, "&amp;", "&")
	t = string.gsub(t, "\n%s*\n+", "\n\n")
	return (string.gsub(t, "^%s*(.-)%s*$", "%1"))
end

-- `fields`: { { label, value } } with nil or empty values left out.
local function facts(fields)
	local items = {}
	for _, f in fields do
		local v = f[2]
		if v ~= nil and v ~= "" and v ~= tern.json.null then
			table.insert(items, { ui.span(f[1], "muted"), ui.span(tostring(v)) })
		end
	end
	return ui.kv(items)
end

-- A detail record (`s.pr` / `s.wi`) still loading or failed; nil when its data is there.
local function pending(entry, what: string)
	if not entry or entry.loading then
		return { ui.progress(nil, "Reading the " .. what .. "…") }
	end
	if entry.error then
		local e = entry.error
		return {
			with(card({ ui.span("Could not read the " .. what, "strong") }, { ui.text(tostring(e.message)), hint(tostring(e.nextStep or "")) }, {
				icon = "warn",
				meta = { ui.span(tostring(e.code), "muted") },
			}), { key = "detail-error", tone = "error" }),
		}
	end
	return nil
end

-- dev answers one object; tolerate a one-item list.
local function record(data)
	if type(data) == "table" and data[1] ~= nil and data.id == nil then
		return data[1]
	end
	return data or {}
end

local function pr_detail(s)
	local waiting = pending(s.pr, "pull request")
	if waiting then
		return waiting
	end
	local p = record(s.pr.data)
	local detail_facts = {
		{ "Status", p.status },
		{ "Branches", tostring(p.sourceBranch or "?") .. " → " .. tostring(p.targetBranch or "?") },
		{ "Repository", p.repository },
		{ "Project", p.project },
		{ "Author", p.author },
	}
	for _, field in pr_date_facts(p) do table.insert(detail_facts, field) end
	local kids = {
		ui.text({ ui.span("#" .. tostring(p.id or "?") .. "  ", "accent"), ui.span(tostring(p.title or s.pr.key), "strong"), ui.span(if p.isDraft then "  draft" else "", "warning") }),
		facts(detail_facts),
	}
	local body = plain(p.description)
	if body ~= "" then
		table.insert(kids, ui.text(ui.span(bounded(body, 2000), "muted")))
	end
	local tools = {}
	if type(p.url) == "string" then
		table.insert(tools, button("Check out as workspace", act("pr.checkout", p.url), { icon = "branch", variant = "primary" }))
		table.insert(tools, button("Open in browser", act("url", p.url), { icon = "open" }))
		table.insert(tools, button("", act("copy", p.url), { icon = "copy", variant = "quiet", title = "Copy URL" }))
	end
	table.insert(kids, with(ui.row(tools), { key = "pr-actions", role = role("actions") }))
	return kids
end

local function wis(s)
	local p = View.page(s, "wis")
	local kids = {
		collection_head("Work items", p, button("Fetch live", "wis.live", { icon = "cloud", variant = "quiet", title = "dev wi list (network)" })),
	}
	if not s.wis then
		table.insert(kids, hint("Reading the cache…"))
		return kids
	end
	if #s.wis == 0 then
		table.insert(kids, hint("No work items in the cache. Fetch live or sync providers."))
		return kids
	end
	if #p.rows == 0 then
		table.insert(kids, hint("No work item matches the filter."))
		return kids
	end
	local rows = {}
	for i, w in p.rows do
		local meta = { "#" .. tostring(w.id or "?") }
		for _, v in { w.type, w.state, w.assignedTo } do
			if v ~= nil and v ~= "" and v ~= tern.json.null then
				table.insert(meta, tostring(v))
			end
		end
		local ref = Store.work_item_action_value(w)
		local tools = { button("Details", if ref then act("wi", ref) else nil, { icon = "info", disabled = if ref then nil else "This cached record lacks its tenant or project; fetch live to refresh it" }) }
		if type(w.url) == "string" then
			table.insert(tools, button("", act("url", w.url), { icon = "open", variant = "quiet", title = "Open in the browser" }))
		end
		table.insert(rows, with(ui.col({
			ui.text(ui.span(bounded(w.title, 120), "strong")),
			ui.text(ui.span(table.concat(meta, " · "), "muted")),
			with(ui.row(tools), { role = role("actions") }),
		}), { key = "wi:" .. tostring(w.tenant or "") .. ":" .. tostring(w.project or "") .. ":" .. tostring(w.id or i), role = role("pr") }))
	end
	table.insert(kids, with(ui.col(rows), { key = "wi-list", role = role("list") }))
	local pg = pager("wis", p)
	if pg then table.insert(kids, pg) end
	return kids
end

local function wi_detail(s)
	local waiting = pending(s.wi, "work item")
	if waiting then
		return waiting
	end
	local w = record(s.wi.data)
	local kids = {
		ui.text(ui.span(tostring(w.title or ("#" .. s.wi.key)), "strong")),
		facts({
			{ "Id", w.id },
			{ "Type", w.type },
			{ "State", w.state },
			{ "Assigned to", w.assignedTo },
			{ "Author", w.author },
			{ "Project", w.project },
			{ "Area", w.areaPath },
			{ "Iteration", w.iterationPath },
		}),
	}
	local body = plain(w.description)
	if body ~= "" then
		table.insert(kids, ui.text(ui.span(bounded(body, 2000), "muted")))
	end
	if type(w.url) == "string" then
		table.insert(kids, with(ui.row({
			button("Open in browser", act("url", w.url), { icon = "open", variant = "primary" }),
			button("", act("copy", w.url), { icon = "copy", variant = "quiet", title = "Copy URL" }),
		}), { key = "wi-actions", role = role("actions") }))
	end
	return kids
end

-- qmd's snippet without its `@@ … @@` hunk line, on one line.
local function snippet(text: any): string
	local t = tostring(text or "")
	t = string.gsub(t, "^@@[^\n]*\n", "")
	return (string.gsub(t, "%s+", " "))
end

local function search(s, opts)
	local kids = {}
	local q = s.search
	local count = if q and q.results then #q.results else nil
	table.insert(kids, section("Search", count, nil))
	if not q then
		table.insert(kids, hint("Type a query and press Enter: qmd searches the indexed mirrors."))
		return kids
	end
	if q.loading then
		table.insert(kids, ui.progress(nil, "Searching for " .. q.query .. "…"))
		return kids
	end
	if q.error then
		table.insert(kids, with(card({ ui.span("Search failed", "strong") }, { ui.text(tostring(q.error.message)) }, {
			icon = "warn",
			meta = { ui.span(tostring(q.error.code), "muted") },
		}), { key = "search-error", tone = "error" }))
		return kids
	end
	if #q.results == 0 then
		table.insert(kids, hint("Nothing matches " .. q.query .. ". Run qmd update after mirrors change."))
		return kids
	end
	local rows, stale = {}, false
	for i, h in q.results do
		local file = tostring(h.file or "?")
		local on_disk = not string.match(file, "^%a+://")
		stale = stale or not on_disk
		local where = (string.match(file, "[^/\\]+$") or file) .. ":" .. tostring(h.line or 1)
		table.insert(rows, with(ui.col({
			ui.text({ ui.span(bounded(h.title or where, 100), "strong"), ui.span("  " .. where, "muted") }),
			ui.text(ui.span(bounded(snippet(h.snippet), 160), "muted")),
		}), {
			key = "hit:" .. tostring(h.docid or i) .. ":" .. tostring(i),
			role = role("ws"),
			title = file .. (if on_disk then "\nClick to open at line " .. tostring(h.line or 1) else "\nNot on disk since the last index; click copies it"),
			actions = { click = act("hit", tostring(i)) },
		}))
	end
	table.insert(kids, with(ui.col(rows), { key = "hit-list", role = role("list") }))
	if stale then
		table.insert(kids, hint("qmd:// results are not where the index saw them; run qmd update to open them."))
	end
	return kids
end

-- An asked value in the block: the field the host made (`opts.ask`), what it is for, and its buttons.
local function ask_card(s, field)
	local q = Store.question(s.ask.kind, s.ask.mount)
	if not q then
		return nil
	end
	local verb = string.upper(string.sub(q.action, 1, 1)) .. string.sub(q.action, 2)
	return with(ui.col({
		ui.text(ui.span(q.text, "muted strong")),
		field,
		ui.row({
			button(verb, "ask.submit", { variant = "primary", icon = q.icon, size = "md" }),
			button("Cancel", "ask.cancel", { variant = "quiet", size = "md" }),
		}),
		hint("Enter: " .. q.action .. " · Esc cancels"),
	}), { key = "ask", role = role("form") })
end

-- `opts.filter`: the native collection input (home, mirrors, prs, wis), a direct child of the root; `opts.query`:
-- the mirror search field; `opts.ask`: the field of `s.ask`. The toolbar, crumb, filter and alerts stay fixed;
-- only `devcli.body` scrolls. New, Add and Settings are not rendered here: the host layers them as overlays.
function View.render(s, opts): (any, any)
	opts = opts or {}
	local screen = s.screen
	local kids = { toolbar(s) }
	local title = if screen == "ws" then tostring(s.selected or "?") elseif screen == "mirror" then (browsed_mirror(s) or {}).name or "Mirror" else DETAIL_TITLE[screen]
	if screen == "mirror" and not (browsed_mirror(s) or {}).name and s.browse and s.browse.root then
		title = (s.browse and s.browse.name) or string.match(tostring(s.browse.root), "[^/\\]+$") or "Mirror"
	end
	if title then
		table.insert(kids, crumb(s, tostring(title)))
	end
	if COLLECTION[screen] and opts.filter then
		table.insert(kids, opts.filter)
	elseif screen == "search" and opts.query then
		table.insert(kids, opts.query)
	end
	if screen == "ws" then
		for _, n in workspace_chrome(s) do
			table.insert(kids, n)
		end
	end
	local alerts = banners(s)
	if #alerts > 0 then
		table.insert(kids, with(ui.col(alerts), { role = role("alerts"), key = "alerts" }))
	end
	-- The asked value's field stays a direct child of the root: main.root.ask.f_ask.
	if s.ask and opts.ask then
		local node = ask_card(s, opts.ask)
		if node then
			table.insert(kids, node)
		end
	end
	local body
	if screen == "ws" then
		body = workspace(s)
	elseif screen == "mirror" then
		body = mirror_detail(s)
	elseif screen == "worksets" then
		body = worksets(s)
	elseif screen == "mirrors" then
		body = mirrors(s)
	elseif screen == "prs" then
		body = prs(s)
	elseif screen == "pr" then
		body = pr_detail(s)
	elseif screen == "wis" then
		body = wis(s)
	elseif screen == "wi" then
		body = wi_detail(s)
	elseif screen == "search" then
		body = search(s, opts)
	elseif screen == "roots" then
		body = roots(s)
	else
		body = home(s)
	end
	table.insert(kids, with(ui.col(body), { role = role("body"), key = "body" }))
	local main = with(ui.col(kids), { role = role("root"), key = "root" })
	local foot = { ui.span(tostring(#s.workspaces) .. " workspaces · " .. tostring(#s.mirrors) .. " mirrors", "muted") }
	if s.loaded_at then
		table.insert(foot, ui.span("  · " .. os.date("%H:%M", s.loaded_at), "muted"))
	end
	local dock = with(ui.row({ ui.text(foot) }), { role = role("dock") })
	return main, dock
end

View.bounded = bounded
View.button = button
View.hint = hint
View.with = with
View.role = role
View.card = card
View.error_body = error_body
View.error_card = error_card

return View
