-- Snapshot collection budgets and cache invalidation, with no live Rex server.
local root = arg[1] or "."
local sessions, views, generations, failures = {}, {}, {}, {}
local calls
local function reset() calls = { total = 0, views = 0, process = 0, title = 0, program_status = 0 } end
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function add_session(name, count)
  local sid = "session:" .. name
  sessions[#sessions + 1] = { session_id = sid, label = name }
  local blocks = {}
  for index = 1, count do
    blocks[#blocks + 1] = { block_id = "block:" .. name .. index, creator_name = "com.superlogical.terminal" }
  end
  views[sid] = { windows = { { window_id = "window:" .. name, layers = { { blocks = blocks } } } } }
  return blocks
end
local blocks = add_session("a", 50)
blocks[#blocks + 1] = { block_id = "app:a", creator_name = "com.example.browser" }
blocks[#blocks + 1] = { block_id = "block:picker", creator_name = "com.superlogical.terminal" }
add_session("b", 50)
os.getenv = function() return "known" end
rex = {
  args = { picker_block_id = "block:picker" },
  call = function(method, args)
    calls.total = calls.total + 1
    if method == "session.list" then
      assert(rex.args.sessions_only and next(args) == nil)
      return { sessions = copy(sessions) }
    end
    if method == "session.attach_all" then
      assert(args.event_scope == (rex.args.live_refresh and "all" or "session"))
      return { sessions = copy(sessions) }
    end
    if method == "server.status" then return { host_id = "host:local" } end
    local name = assert(method:match("^com%.superlogical%.terminal%.(.+)$"), method)
    assert(args.block_id ~= "app:a" and args.block_id ~= "block:picker", "queried a nonterminal or the picker")
    calls[name] = calls[name] + 1
    local failure = name .. ":" .. args.block_id
    if failures[failure] then failures[failure] = nil; return nil, "temporarily unavailable" end
    if name == "process" then
      if failures[args.block_id] then failures[args.block_id] = nil; return nil, "temporarily unavailable" end
      return { foreground = { pid = 123, name = "cargo" } }
    end
    if name == "title" then return { title = "Build", owner = { pid = 123, name = "cargo" } } end
    return { records = { { state = "working", progress = generations[args.block_id] or 0, owner = { pid = 123, name = "cargo" } } } }
  end,
  session = { view = function(args)
    calls.total = calls.total + 1; calls.views = calls.views + 1
    return copy(views[args.session_id])
  end },
}
local function collect(previous, dirty_blocks, dirty_sessions)
  rex.args.live_previous_snapshot = previous
  rex.args.live_dirty_blocks = dirty_blocks
  rex.args.live_dirty_sessions = dirty_sessions
  reset()
  return dofile(root .. "/rust/src/rex_snapshot.lua")
end
local initial = collect()
assert(calls.total == 304 and calls.views == 2 and calls.process == 100)
assert(initial.metadata["app:a"] == nil and initial.metadata["block:picker"] == nil)
rex.args.sessions_only = true
local catalog = collect()
assert(calls.total == 2 and calls.views == 0 and calls.process == 0,
  "session jumps must not attach to sessions or scan their panes")
assert(catalog.sessions_only and #catalog.sessions == 2
  and next(catalog.views) == nil and next(catalog.metadata) == nil)
rex.args.sessions_only = nil
rex.args.live_refresh = true
generations["block:a1"] = 42
local updated = collect(initial, { ["block:a1"] = true }, {})
assert(calls.total == 5 and calls.views == 0 and calls.process == 1, "one terminal change must not query other panes")
assert(updated.metadata["block:a1"].program_status.records[1].progress == 42)
assert(initial.metadata["block:a1"].program_status.records[1].progress == 0, "cache updates must not mutate the prior snapshot")
assert(updated.metadata["block:b1"] == initial.metadata["block:b1"], "reuse unaffected terminal metadata")
views["session:a"].windows[1].label = "renamed"
updated = collect(updated, {}, { ["session:a"] = true })
assert(calls.total == 3 and calls.views == 1 and calls.process == 0, "layout-only changes must preserve terminal metadata")
assert(updated.views["session:a"].windows[1].label == "renamed")
assert(updated.metadata["block:a1"].program_status.records[1].progress == 42)
blocks[#blocks + 1] = { block_id = "block:added", creator_name = "com.superlogical.terminal" }
updated = collect(updated, {}, { ["session:a"] = true })
assert(calls.total == 6 and calls.process == 1 and updated.metadata["block:added"], "new panes still fetch their metadata")
generations["block:a1"] = 43
updated = collect(updated, { ["block:a1"] = true }, { ["session:a"] = true })
assert(calls.total == 6 and calls.process == 1, "terminal and layout events in one batch must refresh the changed process")
assert(updated.metadata["block:a1"].program_status.records[1].progress == 43)
table.remove(sessions, 1); views["session:a"] = nil
updated = collect(updated, {}, { ["session:a"] = true })
assert(calls.total == 2 and updated.views["session:a"] == nil and updated.metadata["block:a1"] == nil, "closed sessions must leave no cached candidates")
add_session("new", 1)
updated = collect(updated, {}, {})
assert(calls.total == 6 and calls.views == 1 and calls.process == 1, "new sessions and panes are always collected")
failures["block:new1"] = true
updated = collect(updated, { ["block:new1"] = true }, {})
assert(calls.total == 3 and updated.metadata["block:new1"] == nil, "failure must remove stale metadata")
updated = collect(updated, {}, {})
assert(calls.total == 5 and updated.metadata["block:new1"] ~= nil, "failed metadata is retried instead of cached")
for _, method in ipairs({ "program_status", "title" }) do
  failures[method .. ":block:new1"] = true
  updated = collect(updated, { ["block:new1"] = true }, {})
  assert(calls.total == 5 and updated.metadata["block:new1"].foreground.pid == 123,
    "partial failure must preserve successful process metadata")
  assert(updated.metadata["block:new1"][method] == nil
      and updated.incomplete_metadata["block:new1"], "partial failure must not look cacheable")
  local successful = method == "title" and "program_status" or "title"
  assert(updated.metadata["block:new1"][successful] ~= nil, "partial failure must preserve other successful metadata")
  updated = collect(updated, {}, {})
  assert(calls.total == 5 and calls.process == 1 and calls[method] == 1,
    "next collection must retry incomplete metadata without requiring another event from that pane")
  assert(updated.metadata["block:new1"][method] ~= nil
      and not updated.incomplete_metadata["block:new1"], "successful retry must clear incomplete state")
  updated = collect(updated, {}, {})
  assert(calls.total == 2 and calls.process == 0, "successful retry restores normal metadata caching")
end
collect()
assert(calls.total == 157 and calls.views == 2 and calls.process == 51, "manual refresh still reads every terminal")
print("passed: 304-to-2 session catalogs, 304-to-5 terminal updates, 153-to-3 layout updates, new/closed panes, simultaneous events, process/title/status retry, explicit refresh")
