--!nonstrict
-- Store state under deferred dev callbacks: root switches, overlapping reads, late answers.
-- Every dev operation answers only when the test says so, so each test is one exact callback schedule.
-- Run from the plugin root: lune run test/state-reliability.luau
local process = require("@lune/process")
local Shim = require("./shim")
local base = string.gsub(process.cwd, "\\", "/")
base = string.gsub(base, "/$", "")
local Store = Shim.load(base .. "/store.luau")
local failures = {}
local function test(name, fn)
	local ok, why = pcall(fn)
	if ok then
		print("PASS " .. name)
	else
		table.insert(failures, name)
		print("FAIL " .. name .. ": " .. tostring(why))
	end
end

-- Timers never fire by themselves; the status chain's gap timer is simply left pending.
Shim.tern.timer = function(_, fn)
	return { cancel = function() end }
end

local function new_dev()
	local dev = { calls = {} }
	function dev.describe(op)
		return op
	end
	function dev.folders()
		return {}
	end
	function dev.git_folder() end
	return setmetatable(dev, {
		__index = function(_, op)
			return function(input, done)
				table.insert(dev.calls, { op = op, input = input, done = done })
			end
		end,
	})
end

local function calls_of(dev, op)
	local out = {}
	for _, c in dev.calls do
		if c.op == op then table.insert(out, c) end
	end
	return out
end
local function latest(dev, op)
	local all = calls_of(dev, op)
	local c = all[#all]
	assert(c ~= nil and not c.answered, "no unanswered " .. op .. " call")
	return c
end
local function answer(call, value)
	assert(not call.answered, "call answered twice")
	call.answered = true
	call.done({ ok = true, value = value }, nil)
end
local function reject(call, err)
	assert(not call.answered, "call answered twice")
	call.answered = true
	call.done({ ok = false, error = err }, nil)
end

local offline = { code = "NETWORK", message = "offline", details = {} }

local function workspaces(root)
	return { { name = "task", path = root .. "/ws/task", mountCount = 1 } }
end

local function store(dev)
	Shim.kv.root = nil
	return Store.new({ surface = "block", dev = dev, redraw = function() end, effect = function() end })
end

-- A store that already read root `root`.
local function in_root(dev, root)
	local s = store(dev)
	s.active_root = root
	s.workspaces = workspaces(root)
	return s
end

-- A store that already read root `root` with workspace "task" selected: a refresh reads the status of the selected
-- workspace (and of the focused one) only, so the status-chain races need it.
local function watching(dev, root)
	local s = in_root(dev, root)
	s.selected, s.screen = "task", "ws"
	return s
end

-- Answers the four list reads of the newest refresh; the status chain it starts stays pending.
local function settle_refresh(dev, root)
	answer(latest(dev, "roots"), { { path = root } })
	answer(latest(dev, "current"), { root = root, source = "default" })
	answer(latest(dev, "workspaces"), workspaces(root))
	answer(latest(dev, "mirrors"), {})
end

local function switch_root(s, dev, root)
	Store.dispatch(s, nil, "root", root)
	settle_refresh(dev, root)
end

local function clean(mount_state)
	return { mounts = { { path = "lib", state = mount_state or "clean", observed = { isDirty = false } } } }
end

test("late dry-run from root A cannot authorize Apply on root B", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.dispatch(s, nil, "update", "task")
	local plan_a = latest(dev, "update")
	assert(plan_a.input.root == "/root-a" and plan_a.input.cwd == "/root-a/ws/task", "The plan must be read in root A's workspace folder")
	switch_root(s, dev, "/root-b")
	answer(plan_a, { mounts = {} })
	assert(s.plan == nil, "A plan read in root A must not become the reviewed plan of root B's workspace of the same name")
	Store.dispatch(s, nil, "apply", nil)
	assert(#calls_of(dev, "update") == 1, "Apply must not start an update without a plan reviewed in this root")
end)

test("dry-run requested before leaving the workspace does not reappear as a plan", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.dispatch(s, nil, "update", "task")
	local plan = latest(dev, "update")
	Store.dispatch(s, nil, "home", nil)
	answer(plan, { mounts = {} })
	assert(s.plan == nil, "A late plan must not authorize Apply after the person navigated away")
end)

for _, ok in { true, false } do
	test("late " .. (if ok then "success" else "failure") .. " from root A leaves root B's operation state alone", function()
		local dev = new_dev()
		local s = in_root(dev, "/root-a")
		Store.dispatch(s, nil, "mirror.sync", "")
		local from_a = latest(dev, "sync_mirrors")
		switch_root(s, dev, "/root-b")
		Store.dispatch(s, nil, "mirror.sync", "")
		local from_b = latest(dev, "sync_mirrors")
		assert(from_b ~= from_a, "Root B must be able to start its own sync while root A's answer is outstanding")
		local roots_before = #calls_of(dev, "roots")
		if ok then
			answer(from_a, { updated = 1, up_to_date = 0, skipped = {} })
		else
			reject(from_a, offline)
		end
		assert(s.failure == nil, "A failure from root A must not become root B's failure card or remedy")
		assert(s.notice == nil, "A result from root A must not announce itself in root B")
		assert(s.busy.sync_mirrors ~= nil, "Root A's answer must not clear root B's busy marker")
		assert(#calls_of(dev, "roots") == roots_before, "Root A's success must not trigger a reload of root B")
		answer(from_b, { updated = 0, up_to_date = 1, skipped = {} })
		assert(s.busy.sync_mirrors == nil, "Root B's own answer clears its marker")
	end)
end

test("a failure card does not survive a root switch", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.dispatch(s, nil, "mirror.sync", "")
	reject(latest(dev, "sync_mirrors"), offline)
	assert(s.failure and #s.failure.remedies > 0, "Precondition: root A shows a retry remedy")
	switch_root(s, dev, "/root-b")
	assert(s.failure == nil, "Root B must not show or retry root A's failure")
end)

test("a retried operation keeps the folder it was first run in", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.dispatch(s, nil, "update", "task")
	answer(latest(dev, "update"), { mounts = {} })
	Store.dispatch(s, nil, "apply", nil)
	reject(latest(dev, "update"), offline)
	assert(s.failure and s.failure.remedies[1] and s.failure.remedies[1].kind == "run", "Precondition: retry offered")
	s.workspaces[1].path = "/root-a/ws/moved"
	Store.dispatch(s, nil, "remedy", "1")
	assert(latest(dev, "update").input.cwd == "/root-a/ws/task", "An explicit working directory must not be replaced from the current list")
end)

test("an input pinned to root A is not resolved through root B's workspaces", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-b")
	local input = { root = "/root-a", ws = "task" }
	s.failure = {
		op = "update",
		input = input,
		label = "Update task",
		error = offline,
		remedies = { { label = "Try again", kind = "run", op = "update", input = input } },
	}
	Store.dispatch(s, nil, "remedy", "1")
	local call = latest(dev, "update")
	assert(call.input.root == "/root-a", "The pinned root must be kept")
	assert(call.input.cwd ~= "/root-b/ws/task", "Root A's workspace must not run in root B's folder; cwd=" .. tostring(call.input.cwd))
end)

test("late pull request answers for root A are dropped in root B", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.load_prs(s, nil, false)
	local from_a = latest(dev, "pull_requests")
	switch_root(s, dev, "/root-b")
	Store.load_prs(s, nil, false)
	local from_b = latest(dev, "pull_requests")
	assert(from_b ~= from_a, "Root B must be able to list its pull requests while root A's answer is outstanding")
	answer(from_a, { { title = "A" } })
	assert(s.prs == nil, "Root A's list must not appear in root B")
	assert(s.busy.pull_requests ~= nil, "Root A's answer must not clear root B's busy marker")
	answer(from_b, { { title = "B" } })
	assert(s.prs and s.prs[1].title == "B" and s.busy.pull_requests == nil, "Root B's own answer is shown")
end)

test("late pull request failure for root A leaves root B without a failure", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.load_prs(s, nil, true)
	local from_a = latest(dev, "pull_requests")
	switch_root(s, dev, "/root-b")
	reject(from_a, offline)
	assert(s.failure == nil and s.prs_error == nil, "Root A's failure must not surface in root B")
end)

test("a failed pull request read is exposed instead of waiting on the cache forever", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.load_prs(s, nil, false)
	reject(latest(dev, "pull_requests"), { code = "ENOENT", message = "no cache", details = {} })
	assert(s.prs == nil and s.prs_error and s.prs_error.code == "ENOENT", "The view needs the read error while no list exists")
	assert(s.busy.pull_requests == nil, "The read is over")
	Store.load_prs(s, nil, false)
	assert(s.prs_error == nil, "A new read starts without the old error")
	answer(latest(dev, "pull_requests"), {})
	assert(s.prs and #s.prs == 0 and s.prs_error == nil, "A good read replaces the error with an (empty) list")
end)

test("late work item answers for root A are dropped in root B", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	Store.load_wis(s, nil, false)
	local from_a = latest(dev, "work_items")
	switch_root(s, dev, "/root-b")
	Store.load_wis(s, nil, false)
	local from_b = latest(dev, "work_items")
	assert(from_b ~= from_a, "Root B must be able to list work items while root A's answer is outstanding")
	answer(from_a, { { title = "A" } })
	assert(s.wis == nil and s.busy.work_items ~= nil, "Root A's answer must not show or clear root B's state")
end)

for _, mode in { "current", "workspaces" } do
	for _, prior in { true, false } do
		test("failed " .. mode .. " read after an abandoned status chain leaves no spinner (" .. (if prior then "with" else "without") .. " earlier data)", function()
			local dev = new_dev()
			local s = watching(dev, "/root-a")
			local earlier = if prior then clean("clean") else nil
			if prior then s.status.task = { data = earlier, loading = false } end
			Store.refresh(s, nil, true)
			settle_refresh(dev, "/root-a")
			local chain = latest(dev, "status")
			assert(s.status.task.loading, "Precondition: the chain is reading")
			Store.refresh(s, nil, true)
			answer(latest(dev, "roots"), { { path = "/root-a" } })
			if mode == "current" then
				reject(latest(dev, "current"), offline)
			else
				answer(latest(dev, "current"), { root = "/root-a", source = "default" })
				reject(latest(dev, "workspaces"), offline)
				answer(latest(dev, "mirrors"), {})
			end
			assert(not s.status.task.loading, "A refresh that failed must not leave the abandoned read spinning")
			answer(chain, clean("dirty"))
			assert(not s.status.task.loading and s.status.task.data == earlier, "The abandoned chain's answer must stay ignored")
			local label = Store.health(s, s.workspaces[1])
			if prior then
				assert(s.status.task.stale and label == "stale", "Earlier observations must read as stale, not clean; label=" .. label)
			else
				assert(label ~= "checking", "Without data the card must not claim it is still checking; label=" .. label)
			end
		end)
	end
end

test("a manual remote check survives a same-root refresh", function()
	local dev = new_dev()
	local s = watching(dev, "/root-a")
	local done = {}
	Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(done, ok) end)
	local manual = latest(dev, "status")
	Store.refresh(s, nil, true)
	settle_refresh(dev, "/root-a")
	local chain = latest(dev, "status")
	assert(chain ~= manual, "Precondition: the refresh reads the workspace itself")
	answer(manual, clean("clean"))
	assert(#done == 1 and done[1] == true, "The caller's completion must run once the answer comes")
	assert(s.notice and s.notice.text == "Remotes checked: task", "The result of the check must still be announced")
	assert(s.busy["check:task"] == nil, "The check is over")
	assert(s.checking.task, "The refresh's own read of the workspace is still in flight")
	answer(chain, clean("clean"))
	assert(not s.checking.task and not s.status.task.loading, "The refresh finishes its own read")
end)

test("a late check answer does not clear a newer check", function()
	local dev = new_dev()
	local s = watching(dev, "/root-a")
	local first_done, second_done = {}, {}
	Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(first_done, ok) end)
	local first = latest(dev, "status")
	Store.refresh(s, nil, true)
	settle_refresh(dev, "/root-a")
	answer(latest(dev, "status"), clean("clean"))
	Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(second_done, ok) end)
	local second = latest(dev, "status")
	answer(first, clean("clean"))
	assert(#first_done == 1, "The first caller is told its check ended")
	assert(s.busy["check:task"] ~= nil and s.checking.task ~= nil and #second_done == 0, "The newer check must stay busy until its own answer")
	answer(second, clean("clean"))
	assert(s.busy["check:task"] == nil and not s.checking.task and #second_done == 1, "The newer check ends with its own answer")
end)

test("a check answered after a root switch reports done but changes nothing", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	local done = {}
	Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(done, ok) end)
	local from_a = latest(dev, "status")
	switch_root(s, dev, "/root-b")
	answer(from_a, clean("dirty"))
	assert(#done == 1 and done[1] == false, "The caller must hear that nothing was applied")
	assert(s.notice == nil, "Root A's remote check must not be announced in root B")
	assert(s.status.task == nil or s.status.task.data == nil, "Root A's observations must not appear under root B's workspace")
end)

test("failed checks are throttled by the last attempt, not the last success", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	s.checked.task = 1
	Store.check(s, nil, "task", { max_age = 60 })
	reject(latest(dev, "status"), offline)
	assert(s.checked.task == 1, "The last success must stay the last success")
	Store.check(s, nil, "task", { max_age = 60 })
	assert(#calls_of(dev, "status") == 1, "A persistent error must not be retried on every focus change")
end)

local function reviewed(dev)
	local s = in_root(dev, "/root-a")
	s.status.task = { data = clean("clean"), loading = false }
	return s
end

test("single removal is not offered from stale observations", function()
	local dev = new_dev()
	local s = reviewed(dev)
	s.status.task.stale = true
	Store.dispatch(s, nil, "remove", "task|lib")
	assert(s.confirm == nil, "A stale observation must not open a removal review")
end)

test("single removal re-checks the observation when confirmed", function()
	local dev = new_dev()
	local s = reviewed(dev)
	Store.dispatch(s, nil, "remove", "task|lib")
	assert(s.confirm, "Precondition: a fresh review asks first")
	s.status.task = { data = clean("clean"), loading = false, stale = true, error = offline }
	Store.dispatch(s, nil, "confirm.yes")
	assert(#calls_of(dev, "remove") == 0, "A review of observations that went stale must not remove anything")
	assert(s.notice and s.notice.tone == "warning", "The person must be told to review again")
end)

test("single removal is refused when the status was replaced after review", function()
	local dev = new_dev()
	local s = reviewed(dev)
	Store.dispatch(s, nil, "remove", "task|lib")
	s.status.task = { data = clean("dirty"), loading = false }
	Store.dispatch(s, nil, "confirm.yes")
	assert(#calls_of(dev, "remove") == 0, "A newer observation changes what was reviewed")
end)

test("a reviewed single removal runs in the reviewed root and folder", function()
	local dev = new_dev()
	local s = reviewed(dev)
	Store.dispatch(s, nil, "remove", "task|lib")
	Store.dispatch(s, nil, "confirm.yes")
	local call = latest(dev, "remove")
	assert(call.input.root == "/root-a" and call.input.cwd == "/root-a/ws/task" and call.input.mount == "lib", "The removal must carry the reviewed context")
end)

test("a batch removal stops when the root changes under it", function()
	local dev = new_dev()
	local s = in_root(dev, "/root-a")
	s.status.task = {
		data = { mounts = {
			{ path = "one", state = "clean", observed = { isDirty = false } },
			{ path = "two", state = "clean", observed = { isDirty = false } },
		} },
		loading = false,
	}
	Store.dispatch(s, nil, "remove.all", "task")
	Store.dispatch(s, nil, "confirm.yes")
	local first = latest(dev, "remove")
	switch_root(s, dev, "/root-b")
	answer(first, {})
	assert(#calls_of(dev, "remove") == 1, "No further mount may be removed after the root changed")
	assert(s.notice == nil and s.busy.remove == nil, "The old root's run must not report into the new root")
end)

test("an old manual check cannot overwrite a newer same-root refresh's observations", function()
	local dev = new_dev()
	local s = watching(dev, "/root-a")
	local done = {}
	Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(done, ok) end)
	local old = latest(dev, "status")
	Store.refresh(s, nil, true)
	settle_refresh(dev, "/root-a")
	local newer = clean("dirty")
	answer(latest(dev, "status"), newer)
	assert(s.status.task.data == newer, "Precondition: the refresh published its observations")
	answer(old, clean("clean"))
	assert(s.status.task.data == newer, "An answer started before the newer read must not replace its observations")
	assert(#done == 1 and done[1] == true, "The old caller still hears its check ended, once")
	assert(s.notice and s.notice.text == "Remotes checked: task", "The old check's own result is still announced")
end)

for _, order in { "older answers first", "younger answers first" } do
	test("two same-root manual checks answered out of order keep the younger result (" .. order .. ")", function()
		local dev = new_dev()
		local s = watching(dev, "/root-a")
		local first_done, second_done = {}, {}
		Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(first_done, ok) end)
		local older = latest(dev, "status")
		Store.refresh(s, nil, true)
		settle_refresh(dev, "/root-a")
		answer(latest(dev, "status"), clean("clean"))
		Store.check(s, nil, "task", { refresh = true }, function(ok) table.insert(second_done, ok) end)
		local younger = latest(dev, "status")
		local younger_data = clean("dirty")
		if order == "older answers first" then
			answer(older, clean("clean"))
			assert(s.status.task.loading, "The younger read is still in flight; an older answer must not end it")
			answer(younger, younger_data)
		else
			answer(younger, younger_data)
			answer(older, clean("clean"))
		end
		assert(s.status.task.data == younger_data, "The younger read's observations must be the ones kept")
		assert(#first_done == 1 and #second_done == 1, "Each caller hears its own check end once")
	end)
end

if #failures > 0 then
	error(tostring(#failures) .. " state reliability regressions failed: " .. table.concat(failures, ", "))
end
print("state reliability passed")
