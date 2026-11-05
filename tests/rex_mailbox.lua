-- Hosted query costs, entirely in memory without a Rex server or UI.
-- lua tests/rex_mailbox.lua [checkout-root]
local root = arg[1] or "."
local real_dofile = dofile
local files, encoded, serial = {}, {}, 0
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for key, item in pairs(value) do result[key] = copy(item) end; return result
end
local function encode(value)
  serial = serial + 1
  local key = "json:" .. serial
  encoded[key] = copy(value)
  return key
end
io.open = function(path, mode)
  if mode == "rb" then
    if not files[path] then return end
    return { read = function() return files[path] end, close = function() return true end }
  end
  assert(mode == "wb")
  return { write = function(_, value) files[path] = value; return true end, close = function() return true end }
end
os.getenv = function() return nil end
os.rename = function(from, to) files[to] = files[from]; files[from] = nil; return true end
os.remove = function(path) files[path] = nil; return true end
local timer, snapshots, operations = nil, 0, {}
local handlers, delayed, cache_inputs = {}, {}, {}
rex = {
  args = { root = root, binary = "/unused/imux", client_id = "client:origin",
    session_id = "session:origin", window_id = "window:origin", block_id = "block:origin" },
  json = { encode = encode, decode = function(text) return copy(assert(encoded[text])) end },
  exec = function() return { ok = true, stdout = "/private-picker\n" } end,
  on = function(name, callback) handlers[name] = callback end,
  every = function(_, callback) timer = callback; return { cancel = function() end } end,
  after = function(delay, callback)
    assert(delay == .25)
    local pending = { callback = callback }
    function pending:cancel() self.cancelled = true end
    delayed[#delayed + 1] = pending
    return pending
  end,
  stop = function() error("unexpected coordinator stop") end,
  log = function(_, message) error(message) end,
  layout = { block = function(value) return value end },
  session = { attach = function() return {} end, disown_block = function() return {} end,
    new_layer = function() return { layer_id = "layer:picker", block_ids = { "block:picker" } } end },
}
dofile = function(path)
  if path == root .. "/rust/src/rex_snapshot.lua" then
    snapshots = snapshots + 1
    cache_inputs[#cache_inputs + 1] = { previous = rex.args.live_previous_snapshot,
      blocks = rex.args.live_dirty_blocks, sessions = rex.args.live_dirty_sessions }
    return { version = 1, sessions = {}, views = { s = { revision = snapshots } }, metadata = {}, errors = {} }
  end
  if path == root .. "/rust/src/rex_activate.lua" then return function() end end
  if path == root .. "/integrations/rex_geometry.lua" then
    return { initial = function() end, observe = function() return { cancel = function() end } end }
  end
  if path == root .. "/integrations/rex_operations.lua" then
    return function(request)
      operations[#operations + 1] = request.operation
      assert(not files["/private-picker/request.json"], "consume request before running its operation")
      return { operation = request.operation }
    end
  end
  return real_dofile(path)
end
real_dofile(root .. "/integrations/rex_coordinator.lua")
assert(timer and snapshots == 1, "opening collects one initial snapshot")
assert(encoded[files["/private-picker/live.json"]].version == 1 and rex.args.live_refresh == true,
  "publish the live protocol marker before Rust starts, preserving full native event subscription")
for id, operation in ipairs({ "preview", "health", "schedule-target", "snapshot", "rename" }) do
  files["/private-picker/request.json"] = encode { version = 1, id = id, operation = operation, args = {} }
  timer()
  local response = encoded[files["/private-picker/response.json"]]
  assert(response.id == id and response.ok and response.data.operation == operation)
  assert(#operations == id, "requests execute exactly once")
  assert(snapshots == (id <= 3 and 1 or id - 2), "read-only queries must not recollect every pane")
  timer()
  assert(#operations == id, "an idle tick must not repeat the last operation")
end
print("passed: read-only mailbox queries skip full snapshots, refresh and mutations still collect once")

local before_events = snapshots
for _ = 1, 100 do
  handlers["terminal.program_status_changed"]({}, { session_id = "s", block_id = "worker" })
end
assert(#delayed == 1 and snapshots == before_events)
delayed[1].callback()
assert(snapshots == before_events + 1 and cache_inputs[#cache_inputs].previous
  and cache_inputs[#cache_inputs].blocks.worker, "native bursts publish one incremental snapshot")
assert(rex.args.live_previous_snapshot == nil and rex.args.live_dirty_blocks == nil
  and rex.args.live_dirty_sessions == nil, "incremental cache hints never leak into an explicit refresh")
assert(encoded[files["/private-picker/snapshot.json"]].views.s.revision == snapshots)
handlers["session_view_changed"]({}, { session_id = "s", revision = 0 })
handlers["terminal.title_changed"]({}, { block_id = "block:picker" })
assert(#delayed == 1, "stale topology and picker rendering must not feed back into more snapshots")
handlers["terminal.pwd_changed"]({}, { block_id = "worker" })
local waiting = delayed[#delayed]
rex.stop = function() end
handlers.session_destroyed({}, { session_id = "session:origin" })
assert(waiting.cancelled and files["/private-picker/live.json"] == nil)
waiting.callback()
assert(snapshots == before_events + 1, "closing the origin cancels pending collection and its protocol marker")
print("passed: live marker, incremental event publication, no feedback loop, and lifecycle cleanup")

files, handlers, delayed, cache_inputs = {}, {}, {}, {}
snapshots = 0
os.getenv = function(key) if key == "INTERDIMUX_LIVE_REFRESH" then return "off" end end
real_dofile(root .. "/integrations/rex_coordinator.lua")
assert(snapshots == 1 and rex.args.live_refresh == false and not files["/private-picker/live.json"])
assert(not handlers.session_view_changed and #delayed == 0, "opt-out starts no live producer or consumer")
print("passed: live refresh opt-out leaves explicit refresh available")
