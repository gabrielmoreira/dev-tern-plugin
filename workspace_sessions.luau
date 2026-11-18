--!nonstrict
-- Workspace destinations in native Tern sessions. Every mutation follows an explicit user choice made on
-- fresh numeric session/tab identities. Observation covers only this window's current host and is never
-- complete, so a workspace without a tab is "not observed", not "closed".

local Store = require("./store")
local Redaction = require("./redaction")

local WorkspaceSessions = {}

local NEW_SESSION = "New session…"

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

local function fail(cx, workspace, err)
	cx:toast("error", "Could not open " .. tostring(workspace.name), Redaction.text(tostring(err)))
end

-- Runs one callback stage; a failure is a redacted toast, never a half-reported state.
local function guarded(cx, workspace, fn)
	local ok, err = pcall(fn)
	if not ok then fail(cx, workspace, err) end
end

-- False once the caller's workspace list changed since the action started.
local function live(cx, workspace, opts): boolean
	if opts and opts.valid and not opts.valid() then
		cx:toast("info", "Workspace list changed", "Choose " .. tostring(workspace.name) .. " again.")
		return false
	end
	return true
end

-- The current session and every real session on its host, each once.
local function read_sessions(cx)
	local current = cx.sessions:current()
	local sessions, seen = {}, {}
	for _, session in cx.sessions:list() do
		if session.host == current.host and not seen[session.id] then
			seen[session.id] = true
			table.insert(sessions, session)
		end
	end
	if not seen[current.id] then table.insert(sessions, 1, current) end
	return current, sessions
end

-- Sessions of `host` as they are now, or nil when the current host moved.
local function fresh_sessions(cx, host)
	local current, sessions = read_sessions(cx)
	if current.host ~= host then return nil end
	return sessions
end

-- Root-independent snapshot of this window's current host; failures are unavailable, never empty-but-complete.
function WorkspaceSessions.observe(cx)
	local snapshot = { available = false, complete = false, host = nil, sessions = {}, tabs = {}, panes = {} }
	local ok, result = pcall(function()
		local current, sessions = read_sessions(cx)
		local out = { available = true, complete = false, host = current.host, sessions = {}, tabs = {}, panes = {} }
		local known = {}
		for _, session in sessions do
			known[session.id] = true
			table.insert(out.sessions, { id = session.id, host = session.host, name = session.name, current = session.id == current.id })
		end
		local tabs = {}
		for _, tab in cx.session:tabs() do
			if known[tab.session] then
				tabs[tab.id] = true
				table.insert(out.tabs, { id = tab.id, session = tab.session, name = tab.name, title = tab.title })
			end
		end
		for _, pane in cx.session:panes() do
			if pane.tab and tabs[pane.tab] then
				table.insert(out.panes, {
					pane = pane.pane, tab = pane.tab, kind = pane.kind, cwd = pane.cwd, path = pane.path,
					block = pane.block, parked = pane.parked,
				})
			end
		end
		return out
	end)
	if ok then return result end
	return snapshot
end

-- Positive presence of `workspace` in `observation`, with nested roots owned by their deepest workspace.
local function presence(observation, workspace, opts)
	if not observation.available then return nil end
	local list, listed = {}, false
	local want = Store.norm(workspace.path)
	for _, entry in if opts and opts.workspaces then opts.workspaces else {} do
		table.insert(list, entry)
		if Store.norm(entry.path) == want then listed = true end
	end
	if not listed then table.insert(list, { name = workspace.name, path = workspace.path }) end
	return Store.match_presence(list, observation)[want]
end

local function focus_destination(cx, destination)
	cx.sessions:switch(destination.session)
	cx.layout:focus(destination.pane)
end

-- Shows the session, then focuses its observed tab or opens a new one at the workspace. Nothing moves or types.
local function open_in_session(cx, workspace, opts, host, session_id)
	guarded(cx, workspace, function()
		if not live(cx, workspace, opts) then return end
		local sessions = fresh_sessions(cx, host)
		local target
		for _, session in sessions or {} do
			if session.id == session_id then target = session end
		end
		if not target then
			cx:toast("warning", "Session is no longer available", "Choose a destination for " .. tostring(workspace.name) .. " again.")
			return
		end
		local entry = presence(WorkspaceSessions.observe(cx), workspace, opts)
		for _, destination in if entry then entry.destinations else {} do
			if destination.session == target.id then
				focus_destination(cx, destination)
				return
			end
		end
		cx.sessions:switch(target.id)
		if not cx.layout:new_tab({ cwd = workspace.path }) then error("the tab was not opened") end
	end)
end

local ask_name

local function resolve_collision(cx, workspace, opts, host, clash)
	cx:pick({
		items = {
			{ label = "Use existing “" .. clash.name .. "”", detail = "Open " .. tostring(workspace.name) .. " in that session", session = clash.id },
			{ label = "Choose another name", detail = "Keep sessions separate", again = true },
		},
		placeholder = "A session named “" .. clash.name .. "” exists",
		action = "choose",
	}):next(function(choice, failure, c)
		local here = c or cx
		if failure then fail(here, workspace, failure) return end
		if not choice then return end
		if choice.again then
			ask_name(here, workspace, opts, host)
		else
			open_in_session(here, workspace, opts, host, choice.session)
		end
	end)
end

function ask_name(cx, workspace, opts, host)
	cx:prompt({ placeholder = "Name for the new session", action = "create" }):next(function(text, failure, c)
		local here = c or cx
		if failure then fail(here, workspace, failure) return end
		if type(text) ~= "string" then return end
		local name = trim(text)
		if name == "" then
			here:toast("warning", "Session name needed", "Enter a name to create a session.")
			return
		end
		guarded(here, workspace, function()
			if not live(here, workspace, opts) then return end
			local sessions = fresh_sessions(here, host)
			if not sessions then
				here:toast("warning", "Session list changed", "Choose a destination for " .. tostring(workspace.name) .. " again.")
				return
			end
			local wanted = string.lower(name)
			for _, session in sessions do
				if string.lower(trim(session.name)) == wanted then
					resolve_collision(here, workspace, opts, host, session)
					return
				end
			end
			here.sessions:create({ name = name, cwd = workspace.path })
		end)
	end)
end

-- Always asks where to open: a real session on this host, or a session the user names.
function WorkspaceSessions.open(cx, workspace, opts)
	guarded(cx, workspace, function()
		if not live(cx, workspace, opts) then return end
		local current, sessions = read_sessions(cx)
		local host = current.host
		local counts = {}
		local entry = presence(WorkspaceSessions.observe(cx), workspace, opts)
		for _, destination in if entry then entry.destinations else {} do
			counts[destination.session] = (counts[destination.session] or 0) + 1
		end
		local names = {}
		for _, session in sessions do names[session.name] = (names[session.name] or 0) + 1 end
		local with, without = {}, {}
		for _, session in sessions do
			local parts = {}
			if session.id == current.id then table.insert(parts, "current") end
			if counts[session.id] then
				table.insert(parts, "has " .. tostring(workspace.name) .. " · " .. counts[session.id] .. (if counts[session.id] == 1 then " tab" else " tabs"))
			end
			if names[session.name] > 1 then table.insert(parts, "session " .. session.id) end
			local item = {
				label = session.name, detail = table.concat(parts, " · "), session = session.id,
				current = session.id == current.id, group = if counts[session.id] then "Open here" else "Sessions",
			}
			table.insert(if counts[session.id] then with else without, item)
		end
		local function by_destination(a, b)
			local ar = if a.label == "Default" then 0 elseif a.current then 1 else 2
			local br = if b.label == "Default" then 0 elseif b.current then 1 else 2
			if ar ~= br then return ar < br end
			local an, bn = string.lower(a.label), string.lower(b.label)
			if an ~= bn then return an < bn end
			return a.session < b.session
		end
		table.sort(with, by_destination)
		table.sort(without, by_destination)
		local items = {}
		for _, item in with do table.insert(items, item) end
		for _, item in without do table.insert(items, item) end
		table.insert(items, { label = NEW_SESSION, detail = "Name it yourself", group = "New", new = true })
		cx:pick({ items = items, placeholder = "Open " .. tostring(workspace.name) .. " in…", action = "open" }):next(function(choice, failure, c)
			local here = c or cx
			if failure then fail(here, workspace, failure) return end
			if not choice then return end
			if choice.new then
				if live(here, workspace, opts) then ask_name(here, workspace, opts, host) end
			else
				open_in_session(here, workspace, opts, host, choice.session)
			end
		end)
	end)
end

-- Focuses an observed tab of the workspace, asking when several exist. Never creates a session or tab.
function WorkspaceSessions.show_open(cx, workspace, opts)
	guarded(cx, workspace, function()
		if not live(cx, workspace, opts) then return end
		local observation = WorkspaceSessions.observe(cx)
		local entry = presence(observation, workspace, opts)
		local destinations = if entry then entry.destinations else {}
		if #destinations == 0 then
			if observation.available then
				cx:toast("info", tostring(workspace.name) .. " not observed", "No tab in this window's current host shows it. Other windows and hosts are unknown.")
			else
				cx:toast("info", "Open tabs unknown", "Tern's sessions and tabs could not be inspected.")
			end
			return
		end
		if #destinations == 1 then
			focus_destination(cx, destinations[1])
			return
		end
		local items = {}
		for _, destination in destinations do
			local tab = if type(destination.tab_name) == "string" and destination.tab_name ~= "" then destination.tab_name else "Tab " .. destination.tab
			table.insert(items, { label = tab, detail = destination.session_name, group = destination.session_name, destination = destination })
		end
		cx:pick({ items = items, placeholder = "Show " .. tostring(workspace.name) .. " in…", action = "show" }):next(function(choice, failure, c)
			local here = c or cx
			if failure then fail(here, workspace, failure) return end
			if not choice then return end
			guarded(here, workspace, function()
				if not live(here, workspace, opts) then return end
				-- Identities may have changed while the picker was open: refocus only the same tab in the same session.
				local observed = WorkspaceSessions.observe(here)
				local fresh = if observed.host == observation.host then presence(observed, workspace, opts) else nil
				for _, destination in if fresh then fresh.destinations else {} do
					if destination.tab == choice.destination.tab and destination.session == choice.destination.session then
						focus_destination(here, destination)
						return
					end
				end
				here:toast("warning", "That tab changed", "Choose " .. tostring(workspace.name) .. " again.")
			end)
		end)
	end)
end

return WorkspaceSessions
