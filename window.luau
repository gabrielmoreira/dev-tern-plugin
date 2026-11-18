--!nonstrict
-- Window effects and placement of the editable native navigator. A pane follows its session's content;
-- forms and settings remain native overlays in the host block.

local Store = require("./store")
local DevCli = require("./devcli")
local ShellEnv = require("./shellenv")
local Redaction = require("./redaction")
local WorkspaceSessions = require("./workspace_sessions")

local OWNER = tern.plugin.id
local PANEL_RATIO = 0.24
local SIDEBAR_COLS = 46
local width_requests = {}
local preferred_widths = {}
local width_serial = 0
local sidebar_navigators = {}
local POLL_MS = 60 * 1000
local KIND = OWNER .. ".panel"

local pending_reconcile = false

local migrated = false

-- Native block identity is explicit; titles are presentation, not ownership.
local function owned(cx): { [number]: boolean }
	local out = {}
	for _, pane in cx.session:panes() do
		if pane.block == KIND then out[pane.pane] = true end
	end
	return out
end

local S
local open_navigator

local function draw(_cx)
	tern.chrome.refresh()
end

local function redraw(_cx)
	tern.chrome.refresh()
end

local function navigation_options()
	local root = tern.kv.get("root")
	return {
		workspaces = S and S.workspaces or {},
		valid = function() return tern.kv.get("root") == root end,
	}
end

local function open_session(cx, name: string, path: string)
	WorkspaceSessions.open(cx, { name = name, path = path }, navigation_options())
end

-- A workspace description, from either surface: a prompt prefilled with the current text, then ws.md rewritten
-- through the live document so an open, unsaved ws.md keeps its edits.
local function describe(cx, data)
	cx:prompt({ value = data.text, placeholder = "Description of " .. tostring(data.ws), icon = "pencil", action = "save" })
		:next(function(text, _, c)
			if type(text) ~= "string" or text == data.text then
				return
			end
			local here = c or cx
			DevCli.set_description({ path = data.path, text = text, docs = here.docs }, function(r, c2)
				local t = c2 or here
				if r.ok then
					t:toast("success", "Description saved", r.value.path)
					tern.kv.set("changed", tern.now())
					Store.refresh(S, t, true)
				else
					t:toast("error", Redaction.text(r.error.message), if r.error.detail ~= nil then Redaction.text(r.error.detail) else nil)
				end
			end)
		end)
end

local function effect(cx, kind: string, data)
	if not cx then
		tern.timer(0, function(c)
			if c then
				effect(c, kind, data)
			end
		end)
		return
	end
	if kind == "open" then
		open_session(cx, data.name, data.path)
	elseif kind == "presence" then
		WorkspaceSessions.show_open(cx, data, navigation_options())
	elseif kind == "git" then
		local ok, err = pcall(function()
			cx.git:open(data.path, { how = "tab" }):next(function(_, failure, c)
				if failure and c then
					c:toast("error", "Git block not opened", tostring(failure))
				end
			end)
		end)
		if not ok then
			cx:toast("error", "Git block not opened", tostring(err))
		end
	elseif kind == "copy" then
		cx:copy(data.text)
		cx:toast("info", "Copied", Redaction.text(data.text))
	elseif kind == "edit" then
		local ok, err = pcall(function()
			cx.docs:open(data.path, { how = "tab", line = tonumber(data.line) })
		end)
		if not ok then
			cx:toast("error", "Could not open " .. tostring(data.path), tostring(err))
		end
	elseif kind == "url" then
		local ok, err = pcall(function() cx:open(data.url) end)
		if not ok then cx:toast("error", "Could not open link", tostring(err)) end
	elseif kind == "ask" then
		local question = Store.question(data.kind, data.mount)
		if question then
			cx:prompt({ value = data.value, placeholder = question.text, icon = question.icon, action = question.action }):next(function(text, _, c)
				if text ~= nil then Store.answer(S, c or cx, data, text) end
			end)
		end
	elseif kind == "describe" then
		describe(cx, data)
	elseif kind == "settings" then
		open_navigator(cx, "settings", nil, tern.kv.get("surface") ~= "panel", true)
	elseif kind == "refresh" then
		-- This store reloads itself; open panel blocks follow the stamp (see host.luau poll).
		tern.kv.set("changed", tern.now())
	end
end

S = Store.new({ surface = "sidebar", dev = DevCli, redraw = redraw, effect = effect })

local function enabled(): boolean
	return tern.kv.get("sidebar") == true
end

local widget_inventory, widget_failures = nil, {}
local widget_title = "Toggle dev sidebar\nLoading workspaces..."
local function update_widget_preview()
	if not widget_inventory then return end
	local presence = Store.match_presence(widget_inventory, S.presence)
	local names, rows = {}, {}
	for _, w in widget_inventory do
		local name = string.lower(w.name)
		names[name] = (names[name] or 0) + 1
	end
	for _, w in widget_inventory do
		table.insert(rows, {
			name = string.lower(w.name), path = w.path,
			label = w.name .. (if names[string.lower(w.name)] > 1 then " (" .. w.path .. ")" else ""),
			observed = presence[Store.norm(w.path)] ~= nil,
		})
	end
	table.sort(rows, function(a, b)
		if a.observed ~= b.observed then return a.observed end
		if a.name ~= b.name then return a.name < b.name end
		return a.path < b.path
	end)
	local lines = { "Toggle dev sidebar", "", if #widget_failures > 0 then "Workspaces (partial)" else "Workspaces" }
	for _, row in rows do
		table.insert(lines, (if row.observed then "[open] " else "") .. row.label)
	end
	if #rows == 0 then
		table.insert(lines, if #widget_failures > 0 then "Workspace preview unavailable" else "No registered workspaces")
	end
	if S.presence and not S.presence.available then table.insert(lines, "Open status unavailable") end
	table.insert(lines, "\nChoose dev: Workspaces to switch.")
	local title = table.concat(lines, "\n")
	if title ~= widget_title then
		widget_title = title
		tern.chrome.refresh()
	end
end

local function first_content(tree, mine): number?
	if not tree then
		return nil
	end
	if tree.pane then
		return if mine[tree.pane] then nil else tree.pane
	end
	for _, child in tree do
		if type(child) == "table" then
			local found = first_content(child, mine)
			if found then
				return found
			end
		end
	end
	return nil
end

local function sidebar_side(): string
	return if tern.kv.get("sidebar_side") == "left" then "left" else "right"
end

-- Find the outer content edge through nested horizontal/vertical splits, without rearranging content.
-- Also return our pane's outer edge so reconciliation leaves an already-correct layout alone.
local function edge_content(tree, mine, side, lo: number, hi: number)
	if not tree then return nil, nil, nil end
	if tree.pane then
		local edge = if side == "right" then hi else lo
		if mine[tree.pane] then return nil, nil, edge end
		return tree.pane, edge, nil
	end
	local mid = lo + (hi - lo) * (tonumber(tree.ratio) or 0.5)
	local horizontal = tree.split == "right"
	local a, ae, own_a = edge_content(tree[1], mine, side, lo, if horizontal then mid else hi)
	local b, be, own_b = edge_content(tree[2], mine, side, if horizontal then mid else lo, hi)
	local own = own_a or own_b
	if not a then return b, be, own end
	if not b then return a, ae, own end
	if (side == "right" and be >= ae) or (side == "left" and be < ae) then return b, be, own end
	return a, ae, own
end

-- The workspace holding the focused pane, so its row can be highlighted.
local function track_active(cx)
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	local found = Store.locate(S, info and info.cwd)
	if found and found.name ~= S.active_ws then
		S.active_ws = found.name
		return true
	elseif not found and S.active_ws ~= nil then
		S.active_ws = nil
		return true
	end
	return false
end
-- The native blocks live in the host VM; only the window can observe sessions and tabs. Send stable,
-- root-independent metadata to each navigator, without a dev CLI read or an all-window absence claim.
local presence_targets, presence_sent = {}, {}
local preview_presence_payload
local function publish_presence(cx, force: boolean?)
	local observation = WorkspaceSessions.observe(cx)
	Store.set_presence(S, observation)
	local payload = tern.json.encode(observation)
	if payload ~= preview_presence_payload then
		preview_presence_payload = payload
		update_widget_preview()
	end
	local ok, panes = pcall(function() return cx.session:panes() end)
	if ok then
		local tabs = {}
		for _, tab in observation.tabs do tabs[tab.id] = true end
		local targets = {}
		for _, pane in panes do
			if pane.block == KIND and pane.tab and tabs[pane.tab] then targets[pane.pane] = true end
		end
		-- Inspection failures still invalidate the last known recipients' positive observations.
		if observation.available then presence_targets = targets end
	end
	for pane in presence_targets do
		if force or presence_sent[pane] ~= payload then
			local sent = pcall(function()
				cx.session:event(pane, { ev = "action", act = "presence.snapshot", value = payload })
			end)
			if sent then presence_sent[pane] = payload else presence_targets[pane], presence_sent[pane] = nil, nil end
		end
	end
	for pane in presence_sent do if not presence_targets[pane] then presence_sent[pane] = nil end end
end


-- Recover an existing native pane by session, including a pane parked by Hide.
open_navigator = function(cx, action: string?, value: string?, sidebar: boolean, focus: boolean, place: boolean?)
	if not migrated then
		migrated = true
		-- Retire only this plugin's obsolete persistent surfaces, never shells or content panes.
		for _, panel in cx.canvas:list() do
			if panel.owner == OWNER and panel.title == "dev" then cx.layout:close(panel.pane) end
		end
		for _, pane in cx.session:panes() do
			if pane.block == OWNER .. ".settings" then cx.layout:close(pane.pane) end
		end
	end
	if sidebar and focus then tern.kv.set("sidebar", true) end
	local current = cx.sessions:current()
	local key = "navigator:" .. tostring(current.host) .. ":" .. tostring(current.id)
	local cached = tern.kv.get(key)
	local info = cached and cx.session:pane(cached)
	if not info or info.block ~= KIND then
		info = nil
		local tabs = {}
		for _, tab in cx.session:tabs() do tabs[tab.id] = tab.session end
		for _, pane in cx.session:panes() do
			if pane.block == KIND and pane.tab and tabs[pane.tab] == current.id then info = pane break end
		end
	end
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local layout = tab and cx.session:layout(tab)
	local mine = owned(cx)
	local anchor = if focused and not mine[focused] then focused else first_content(layout and layout.root, mine)
	local dir = if sidebar then sidebar_side() else "right"
	local content_edge, own_edge
	if sidebar then
		anchor, content_edge, own_edge = edge_content(layout and layout.root, mine, dir, 0, 1)
	end
	if not anchor and not info then return nil end
	local pane = info and info.pane
	local target_cols = (pane and preferred_widths[pane]) or SIDEBAR_COLS
	local placed = false
	if pane then
		local was_parked = info.parked
		if info.parked then
			local ok, why = cx.layout:unpark(pane, { focus = false })
			if not ok then cx:toast("error", "Could not show dev", tostring(why)) return nil end
		end
		local wrong_edge = sidebar and own_edge and content_edge
			and (if dir == "right" then own_edge < content_edge - 0.000001 else own_edge > content_edge + 0.000001)
		if anchor and (place or was_parked or cx.session:tab_of(pane) ~= tab or wrong_edge) then
			if not cx.layout:move(pane, anchor, dir, { focus = focus }) then
				cx:toast("error", "Could not move dev to this tab")
				return nil
			end
			placed = true
		end
		if action then cx.session:event(pane, { ev = "action", act = action, value = value }) end
		if focus then cx.layout:focus(pane) end
	else
		local args = if action then { if action == "create" then "create" else action } else nil
		if args and value then table.insert(args, value) end
		pane = cx:new_block(KIND, args, "beside", {
			target = anchor, dir = dir,
			ratio = if sidebar then PANEL_RATIO else 0.5, focus = focus,
		})
		if not pane then cx:toast("error", "The dev navigator is not loaded on this host", "Reload the plugin and try again.") return nil end
		placed = true
	end
	tern.kv.set(key, pane)
	if sidebar then
		sidebar_navigators[key] = { pane = pane, tab = tab }
	else
		sidebar_navigators[key] = nil
	end
	if sidebar and placed then
		width_serial += 1
		preferred_widths[pane] = target_cols
		width_requests[pane] = { tab = tab, dir = dir, request = tostring(width_serial), target = target_cols, seen = {} }
		cx.session:event(pane, { ev = "action", act = "sidebar.measure", value = tostring(width_serial) })
	end
	return pane
end

local function set_surface(cx, panel: boolean, focus: boolean)
	tern.kv.set("surface", if panel then "panel" else "sidebar")
	tern.kv.set("sidebar", not panel)
	open_navigator(cx, nil, nil, not panel, focus, true)
end

local function park_navigators(cx)
	for _, pane in cx.session:panes() do
		if pane.block == KIND and not pane.parked then
			local ok, why = cx.layout:park(pane.pane)
			if not ok then cx:toast("error", "Could not hide dev", tostring(why)) end
		end
	end
end

local function reconcile(cx)
	if enabled() then
		local current = cx.sessions:current()
		local key = "navigator:" .. tostring(current.host) .. ":" .. tostring(current.id)
		local tracked = sidebar_navigators[key]
		if tracked then
			local info = cx.session:pane(tracked.pane)
			if not info or info.parked then
				local tab_exists = false
				for _, tab in cx.session:tabs() do
					if tab.id == tracked.tab then tab_exists = true break end
				end
				if (info and info.parked) or tab_exists then
					-- Closing/parking the block means hide. A closed tab instead transfers the sidebar.
					tern.kv.set("sidebar", false)
					sidebar_navigators[key] = nil
					park_navigators(cx)
					tern.chrome.refresh()
					return
				end
			end
		end
		open_navigator(cx, nil, nil, true, false)
	elseif tern.kv.get("surface") ~= "panel" then
		park_navigators(cx)
	end
end

local function schedule()
	if pending_reconcile then
		return
	end
	pending_reconcile = true
	tern.timer(120, function(cx)
		pending_reconcile = false
		if cx then
			local ok, err = pcall(reconcile, cx)
			if not ok then
				tern.log.warn("devcli: reconcile failed: " .. tostring(err))
			end
			if track_active(cx) then
				for pane in owned(cx) do cx.session:event(pane, { ev = "action", act = "active", value = S.active_ws, root = S.active_root }) end
				draw(cx)
			end
			publish_presence(cx)
		end
	end)
end

local function show(cx)
	set_surface(cx, false, true)
	if S.loaded_at == nil and not S.loading then
		Store.refresh(S, cx)
	end
end

local function hide(cx)
	tern.kv.set("sidebar", false)
	park_navigators(cx)
end

-- What "dev: Open" (and its key) shows: kv "surface", set on the plugin's settings block.
local function surface(): string
	return if tern.kv.get("surface") == "panel" then "panel" else "sidebar"
end

local function open_workspace(cx, name: string)
	local sidebar = surface() ~= "panel"
	if sidebar then tern.kv.set("sidebar", true) end
	open_navigator(cx, "ws", name, sidebar, true)
end

local function add_folder(cx, path: string, ws: string, ws_path: string, root: string?)
	local normalized_path = string.gsub(string.gsub(path, "\\", "/"), "/+$", "")
	local name = string.match(normalized_path, "[^/]+$")
	if not name or name == "." or name == ".." then
		cx:toast("error", "Cannot name this mount", path)
		return
	end
	local dest = ws_path .. "/" .. name
	for _, m in (S.status[ws] and S.status[ws].data and S.status[ws].data.mounts) or {} do
		if Store.norm(m.path) == Store.norm(name) then
			cx:toast("warning", "Folder already present", "Mount " .. name .. " already exists in " .. ws)
			return
		end
	end
	for _, f in S.folders[ws] or {} do
		if Store.norm(f.path) == Store.norm(dest) then
			cx:toast("warning", "Folder already present", "Folder already exists at " .. dest)
			return
		end
	end
	local exists_ok, exists = pcall(tern.fs.exists, dest)
	if not exists_ok then
		cx:toast("error", "Could not check the destination folder", tostring(exists))
		return
	elseif exists then
		cx:toast("warning", "Folder already present", dest)
		return
	end
	local command = DevCli.describe("add", { ws = ws, repo = path, path = name })
	if root then
		command ..= ' --root "' .. string.gsub(root, '"', '\\"') .. '"'
	end
	cx:pick({
		items = {
			{ label = "Run add", detail = command, icon = "plus", confirm = true },
			{ label = "Cancel", icon = "x", cancel = true },
		},
		placeholder = "Confirm exact command",
		icon = "warn",
		action = "confirm",
	}):next(function(choice, _, c)
		if not choice or not choice.confirm then return end
		DevCli.add({ root = root, cwd = ws_path, ws = ws, repo = path, path = name }, function(r, c2)
			local t = c2 or c or cx
			if r.ok then
				t:toast("success", "Repository added", dest)
				Store.refresh(S, t, true)
			else
				t:toast("error", Redaction.text(r.error.message), if r.error.detail ~= nil then Redaction.text(r.error.detail) else nil)
			end
		end)
	end)
end

local function local_files_host(host: string, cx): boolean
	if host == "" or string.lower(host) == "local" then return true end
	for _, known in cx.hosts:list() do
		if string.lower(known.name) == string.lower(host) then
			return known.kind == "local"
		end
	end
	return false
end

tern.files.button({
	id = OWNER .. "-add",
	title = "Add to dev workspace",
	icon = "plus",
	run = function(files, cx)
		if not local_files_host(files.host, cx) then
			cx:toast("error", "Cannot add from this Files host", "dev ws add runs locally; use a local Files pane.")
			return
		end
		local path = files.root
		if type(path) ~= "string" or path == "" then
			cx:toast("error", "No folder selected", "Open a local folder in Files first.")
			return
		end
		local found = Store.locate(S, path)
		if found then
			open_workspace(cx, found.name)
			return
		end
		local root = S.active_root
		local workspaces = table.clone(S.workspaces)
		DevCli.git_folder(path, function(repo, c)
			local t = c or cx
			if not repo then
				t:toast("error", "Not a Git repository", path)
				return
			end
			local items = {}
			for _, w in workspaces do
				table.insert(items, { label = w.name, detail = w.path, icon = "folder", ws_path = w.path, root = root })
			end
			if #items == 0 then
				t:toast("error", "No workspaces available", "Reload workspaces and try again.")
				return
			end
			t:pick({ items = items, placeholder = "Add repository to workspace", icon = "plus" })
				:next(function(choice, _, c2)
					if choice then add_folder(c2 or t, path, choice.label, choice.ws_path, choice.root) end
				end)
		end)
	end,
})

local function goto_workspace(cx)
		local items = {}
		local focused = cx.session:focused()
		local pane = focused and cx.session:pane(focused)
		local current = Store.locate(S, pane and pane.cwd)
		for _, w in S.workspaces do
			table.insert(items, { label = w.name, detail = w.path, icon = "folder", current = current == w })
		end
		if #items == 0 then
			cx:toast("info", "No workspaces", "Create a workspace with dev: New workspace.")
			return
		end
		cx:pick({ items = items, placeholder = "Go to workspace", icon = "folder", action = "open" })
			:next(function(choice, _, c)
				if choice then
					local w = Store.workspace(S, choice.label)
					if w then open_session(c or cx, w.name, w.path) end
				end
			end)
end

tern.command({
	id = "goto",
	title = "dev: Go to workspace",
	icon = "folder",
	keys = { "ctrl+alt+shift+f12" },
	run = function(cx)
		if S.loaded_at == nil then
			S.after_load = function(c)
				goto_workspace(c or cx)
			end
			Store.refresh(S, cx)
		else
			goto_workspace(cx)
		end
	end,
})

tern.command({
	id = "search",
	title = "dev: Search mirrors",
	icon = "search",
	run = function(cx)
		open_navigator(cx, "search", nil, surface() ~= "panel", true)
	end,
})

tern.command({
	id = "here",
	title = "dev: Show workspace here",
	icon = "folder-open",
	run = function(cx)
		local focused = cx.session:focused()
		local pane = focused and cx.session:pane(focused)
		local w = Store.locate(S, pane and pane.cwd)
		if w then open_workspace(cx, w.name) end
	end,
})

tern.command({
	id = "check",
	title = "dev: Check workspace remotes",
	icon = "refresh",
	run = function(cx)
		local focused = cx.session:focused()
		local pane = focused and cx.session:pane(focused)
		local w = Store.locate(S, pane and pane.cwd)
		if w then Store.check(S, cx, w.name, { refresh = true }, function() tern.chrome.refresh() end) end
	end,
})

tern.chrome.status(function(pane)
	local w = Store.locate(S, pane.cwd)
	if not w then return nil end
	local health, tone = Store.health(S, w)
	return {
		{ text = w.name, icon = "folder", command = "plugin." .. OWNER .. ".here" },
		{ text = health, icon = "activity", tone = tone, command = "plugin." .. OWNER .. ".check" },
	}
end)

local function open_panel(cx)
	set_surface(cx, true, true)
end

local function toggle_sidebar(cx)
	if enabled() then
		hide(cx)
	else
		show(cx)
	end
end

-- Startup and the explicit workspace command share one inventory reader. Widget rendering only reads
-- the formatted cache; native destinations are revalidated when a picker item is selected.
local function read_widget_inventory(cx, done)
	local inventory, seen, failures = {}, {}, {}
	local function finish(here)
		widget_inventory, widget_failures = inventory, failures
		Store.set_presence(S, WorkspaceSessions.observe(here))
		update_widget_preview()
		if done then done(inventory, failures, here) end
	end
	DevCli.roots(nil, function(result, c)
		local here = c or cx
		if not result.ok then
			table.insert(failures, tostring(result.error.message))
			finish(here)
			return
		end
		local roots, known = {}, {}
		for _, root in result.value do
			local path = Store.norm(root.path)
			if path ~= "" and not known[path] then
				known[path] = true
				table.insert(roots, root)
			end
		end
		local function read_root(index, current)
			local root = roots[index]
			if not root then finish(current) return end
			DevCli.workspaces({ root = root.path }, function(list, next_cx)
				if list.ok then
					for _, w in list.value do
						local path = Store.norm(w.path)
						if path ~= "" and not seen[path] then
							seen[path] = true
							table.insert(inventory, w)
						end
					end
				else
					table.insert(failures, root.path .. ": " .. tostring(list.error.message))
				end
				read_root(index + 1, next_cx or current)
			end)
		end
		read_root(1, here)
	end)
end

local preview_started = false
local function start_widget_preview(cx)
	if preview_started then return end
	preview_started = true
	read_widget_inventory(cx)
end

local function widget_menu(cx)
	read_widget_inventory(cx, function(inventory, failures, here)
		local observation = S.presence
		local presence = Store.match_presence(inventory, observation)
		local focused = here.session:focused()
		local workspaces = {}
		for _, w in inventory do
			local entry = presence[Store.norm(w.path)]
			local current = false
			if entry then
				for _, destination in entry.destinations do
					if destination.pane == focused then current = true break end
				end
			end
			table.insert(workspaces, {
				label = w.name,
				detail = w.path .. (if entry then " · " .. tostring(entry.count) .. " open tab(s)" else " · Not observed in this window"),
				icon = "folder", current = current, observed = entry ~= nil, workspace = w,
			})
		end
		table.sort(workspaces, function(a, b)
			if a.current ~= b.current then return a.current end
			if a.observed ~= b.observed then return a.observed end
			local la, lb = string.lower(a.label), string.lower(b.label)
			if la ~= lb then return la < lb end
			return a.detail < b.detail
		end)
		if not observation.available then table.insert(failures, "Native workspace observation is unavailable.") end
		if #failures > 0 then
			here:toast("warning", "Workspace list is incomplete", Redaction.text(table.concat(failures, "\n")))
		end
		here:pick({
			items = workspaces,
			placeholder = if #failures > 0 then "dev · Workspaces (partial)" else "dev · Workspaces",
			icon = "folder", action = "select",
		}):next(function(choice, _, c)
			if not choice then return end
			local selected = c or here
			if choice.workspace then
				if choice.observed then
					WorkspaceSessions.show_open(selected, choice.workspace, { workspaces = inventory })
				else
					WorkspaceSessions.open(selected, choice.workspace, { workspaces = inventory })
				end
			end
		end)
	end)
end

tern.command({ id = "menu", title = "dev: Workspaces", icon = "folder", run = widget_menu })
tern.chrome.widget("dev", {
	name = "dev",
	description = "Click to toggle the sidebar; hover to preview workspaces. Choose dev: Workspaces to switch.",
	icon = "folder",
	render = function(_pane)
		return {
			text = "dev", tone = if enabled() then "accent" else nil,
			title = widget_title,
			command = "plugin." .. OWNER .. ".sidebar",
		}
	end,
})

tern.command({
	id = "open",
	title = "dev: Open",
	icon = "folder",
	keys = { "ctrl+alt+shift+d" },
	run = function(cx)
		if surface() == "panel" then
			open_panel(cx)
		else
			toggle_sidebar(cx)
		end
	end,
})

tern.command({ id = "sidebar", title = "dev: Toggle sidebar", icon = "sidebar", run = toggle_sidebar })

tern.command({ id = "panel", title = "dev: Open panel", icon = "folder", run = open_panel })

local function configure_environment(cx)
	local config = ShellEnv.config()
	cx:pick({
		placeholder = "Execution environment for dev",
		items = {
			{ label = "Inherited environment", detail = "Default. Never executes shell profiles.", kind = "inherited", current = config.mode ~= "shell" },
			{ label = "PowerShell profiles", detail = "Opt-in: executes profiles and prompt hooks in each command directory.", kind = "pwsh" },
			{ label = "Bash profiles", detail = "Opt-in: executes login/interactive startup files and prompt hooks.", kind = "bash" },
			{ label = "Zsh profiles", detail = "Opt-in: executes login/interactive startup files and prompt hooks.", kind = "zsh" },
		},
	}):next(function(choice, _, c)
		if not choice then return end
		local here = c or cx
		if choice.kind == "inherited" then
			ShellEnv.configure(nil, nil)
			tern.kv.set("changed", tern.now())
			Store.refresh(S, here, true)
			here:toast("success", "Using Tern's inherited environment", "No shell profiles will be executed.")
			return
		end
		local suggested = if config.kind == choice.kind then config.shell else nil
		if not suggested and choice.kind ~= "pwsh" then suggested = tern.getenv("SHELL") end
		if not suggested and choice.kind == "pwsh" and tern.runtime.os == "windows" then
			local programs = tern.getenv("ProgramFiles")
			if programs then suggested = programs .. "/PowerShell/7/pwsh.exe" end
		end
		here:prompt({ value = suggested, placeholder = "Absolute path to the " .. choice.kind .. " executable", action = "review" })
			:next(function(path, _, c2)
				if type(path) ~= "string" or path == "" then return end
				local review = c2 or here
				review:pick({
					placeholder = "Allow profile execution by " .. path .. "?",
					items = {
						{ label = "Cancel", detail = "Keep the current execution environment." },
						{ label = "Enable profile execution", enable = true, detail = "Runs ALL startup commands, including credential tools. Captured variables stay only in memory; cached per directory until refreshed." },
					},
				}):next(function(consent, _, c3)
					if not consent or not consent.enable then return end
					local target = c3 or review
					local ok, err = ShellEnv.configure(choice.kind, path)
					if not ok then target:toast("error", "Environment not changed", err) return end
					tern.kv.set("changed", tern.now())
					Store.refresh(S, target, true)
					target:toast("success", "Shell initialization enabled", "Refresh environment in dev settings after changing toolchain configuration.")
				end)
			end)
	end)
end

tern.command({ id = "environment", title = "dev: Execution environment", icon = "terminal", run = configure_environment })

tern.command({
	id = "settings",
	title = "dev: Settings",
	icon = "sliders",
	run = function(cx)
		effect(cx, "settings", {})
	end,
})

tern.command({
	id = "new",
	title = "dev: New workspace",
	icon = "folder-plus",
	run = function(cx)
		open_navigator(cx, "create", nil, surface() ~= "panel", true)
	end,
})

tern.command({
	id = "refresh",
	title = "dev: Reload workspaces",
	icon = "refresh",
	run = function(cx)
		tern.kv.set("changed", tern.now())
		Store.refresh(S, cx, true)
	end,
})


local function decode(s: string): string
	return (string.gsub(string.gsub(s, "%+", " "), "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `devcli://<kind>?k=v&…` from the host block.
tern.route.link(function(link, cx)
	local kind, query = string.match(link.url, "^devcli://([%w%._-]+)%??(.*)$")
	if not kind then
		return nil
	end
	local data = {}
	for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do
		data[decode(k)] = decode(v)
	end
	if kind == "presence.refresh" then
		publish_presence(cx, true)
		-- A freshly created host block may not have mounted when its first event was sent.
		for pane, pending in width_requests do
			cx.session:event(pane, { ev = "action", act = "sidebar.measure", value = pending.request })
		end
	elseif kind == "sidebar.width" then
		local pane, cols = tonumber(data.pane), tonumber(data.cols)
		local pending = pane and width_requests[pane]
		if pending and pending.request == data.request and cols and cols > 0 then
			local info = cx.session:pane(pane)
			if not enabled() or not info or info.block ~= KIND or info.tab ~= pending.tab or info.parked
				or cols == pending.target or pending.seen[cols] then
				width_requests[pane] = nil
			else
				pending.seen[cols] = true
				local delta = pending.target - cols
				if pending.delta and pending.delta * delta < 0 and math.abs(delta) > 1 then
					delta = if delta > 0 then math.floor(delta / 2) else math.ceil(delta / 2)
				end
				pending.delta = delta
				if cx.layout:resize(pane, if pending.dir == "right" then "left" else "right", delta) then
					-- Read back the actual width: cell-to-divider conversion can round or clamp.
					cx.session:event(pane, { ev = "action", act = "sidebar.measure", value = pending.request })
				else
					width_requests[pane] = nil
				end
			end
		elseif not pending and not data.request and pane and cols and cols > 0 then
			local info = cx.session:pane(pane)
			if enabled() and info and info.block == KIND and not info.parked then
				preferred_widths[pane] = cols
			end
		end
	elseif kind == "refresh" then
		Store.refresh(S, cx)
	elseif kind == "environment" then
		configure_environment(cx)
	elseif kind == "environment.refresh" then
		ShellEnv.refresh()
		tern.kv.set("changed", tern.now())
		Store.refresh(S, cx, true)
	elseif kind == "show" then
		local workspace = Store.workspace(S, data.name)
		if not workspace then
			cx:toast("error", "Workspace is not available", tostring(data.name or ""))
		elseif data.path and Store.norm(data.path) ~= Store.norm(workspace.path) then
			cx:toast("error", "Workspace root mismatch", "Reload workspaces and try again.")
		else
			open_workspace(cx, workspace.name)
		end
	elseif kind == "surface" then
		set_surface(cx, data.value == "panel", false)
	elseif kind == "sidebar.side" and (data.value == "left" or data.value == "right") then
		tern.kv.set("sidebar_side", data.value)
		if enabled() then set_surface(cx, false, false) end
	else
		effect(cx, kind, data)
	end
	return { handled = true }
end)

local function check_focused(cx)
	if not cx then return end
	local focused = cx.session:focused()
	local pane = focused and cx.session:pane(focused)
	local w = Store.locate(S, pane and pane.cwd)
	if w then Store.check(S, cx, w.name, { max_age = 60 }, function() tern.chrome.refresh() end) end
	tern.chrome.refresh()
end

tern.on("focus", function(_, cx)
	schedule()
	check_focused(cx)
end)

for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed", "cwd", "title", "session_ended" } do
	tern.on(name, function(_, cx)
		schedule()
		check_focused(cx)
	end)
end

-- Best effort: a `dev …` typed in a shell may have changed workspaces. Needs shell integration (OSC 133),
-- and sees the line as typed; the primary refresh is each action's own callback plus the poll.
tern.on("command_finished", function(ev, cx)
	if enabled() and type(ev.line) == "string" and string.match(ev.line, "^%s*dev%s") then
		Store.refresh(S, cx)
	end
end)

tern.on("window_start", function(cx)
	Store.refresh(S, cx)
	start_widget_preview(cx)
	schedule()
	check_focused(cx)
end)

-- Reload creates a new window VM without replaying window_start.
tern.timer(0, function(cx)
	start_widget_preview(cx)
	schedule()
end)

local function poll(cx)
	if cx and enabled() and next(owned(cx)) ~= nil then
		Store.refresh(S, cx)
	end
	tern.timer(POLL_MS, poll)
end
tern.timer(POLL_MS, poll)

-- Metadata-only recovery for changes whose events were not delivered to this window. Unchanged snapshots
-- are not republished, and unavailable coverage never turns into a "closed" workspace.
local function presence_poll(cx)
	if cx and (enabled() or next(presence_targets) ~= nil) then publish_presence(cx) end
	tern.timer(2 * 1000, presence_poll)
end
tern.timer(2 * 1000, presence_poll)
