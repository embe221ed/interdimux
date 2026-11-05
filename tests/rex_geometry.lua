-- Nonblocking geometry seed/cache tests; no Rex connection or UI mutation.
-- lua tests/rex_geometry.lua [checkout-root]
local root = arg[1] or "."
local geometry = dofile(root .. "/integrations/rex_geometry.lua")
local args = { client_id = "app", session_id = "session", window_id = "window", block_id = "source" }
local bounds = { .11, .17, .78, .66 }
local function fixture()
  local source = { owner = "app", columns = 100, rows = 40, cell_width_px = 21, cell_height_px = 66,
    desired = { { client_id = "other", columns = 20, rows = 10 }, { client_id = "app", columns = 105, rows = 41 } } }
  local view = { windows = { { window_id = "window", layers = { {
    bounds = { 0, 0, 1, 1 }, layout = { rect = { 0, 0, 1, 1 }, split = {
      before = { block_id = "source", rect = { 0, 0, .5, 1 } },
      after = { block_id = "other", rect = { .5, 0, .5, 1 } },
    } },
  } } } } }
  local calls = {}
  local rx = {
    session = { view = function(payload)
      assert(payload.session_id == "session"); calls[#calls + 1] = "view"; return view
    end },
    call = function(method, payload)
      assert(method == "com.superlogical.terminal.size", "geometry must never mutate app state")
      assert(payload.session_id == "session" and payload.block_id == "source")
      calls[#calls + 1] = "size"; return source
    end,
  }
  return rx, source, view, calls
end
local rx, source, view, calls = fixture()
local hint, fingerprint = geometry.initial(rx, args, bounds)
assert(hint.columns == 163 and hint.rows == 27, "seed from initiating app grid and split fractions")
assert(not hint.cell_width_px and not hint.cell_height_px, "never impose the source pane's zoomed font")
assert(type(fingerprint) == "string" and #calls == 2, "initial performs only view+source-size reads")
print("passed: immediate seed, split rect, two read-only calls, no font inheritance")
local cache = { cells = { width = 17, height = 55 }, windows = {} }
hint = geometry.initial(rx, args, bounds, cache)
assert(hint.columns == 202 and hint.rows == 32, "known popup cells recover viewport pixels from source grid")
assert(hint.cell_width_px == 17 and hint.cell_height_px == 55, "only verified popup metrics are seeded")
cache.windows.window = { fingerprint = fingerprint, size = { columns = 199, rows = 31, cell_width_px = 17, cell_height_px = 55 } }
hint = geometry.initial(rx, args, bounds, cache)
assert(hint.columns == 199 and hint.rows == 31, "exact geometry reuses observed grid")
hint.columns = 1
assert(cache.windows.window.size.columns == 199, "returned hints cannot corrupt cached values")
local saved_entry = cache.windows.window
for _, invalid in ipairs({ 42, "invalid", false }) do
  cache.windows.window = invalid
  hint = geometry.initial(rx, args, bounds, cache)
  assert(hint.columns == 202 and hint.rows == 32, "malformed optional cache entries must use the estimate")
end
cache.windows.window = saved_entry
hint = geometry.initial(rx, args, bounds, 42)
assert(hint.columns == 163 and not hint.cell_width_px, "malformed cache containers cannot block opening")
print("passed: default popup cells, exact fingerprint cache, copy isolation")
local function invalidates(change, restore)
  change()
  local _, changed = geometry.initial(rx, args, bounds, cache)
  assert(changed ~= fingerprint, "changed geometry must not reuse stale cached size")
  restore()
end
invalidates(function() bounds[1] = .12 end, function() bounds[1] = .11 end)
invalidates(function() bounds[3] = .7 end, function() bounds[3] = .78 end)
invalidates(function() source.owner = "other" end, function() source.owner = "app" end)
invalidates(function() source.columns = 99 end, function() source.columns = 100 end)
invalidates(function() source.desired[2].columns = 106 end, function() source.desired[2].columns = 105 end)
invalidates(function() source.cell_width_px = 22 end, function() source.cell_width_px = 21 end)
invalidates(function() view.windows[1].zoomed_block_id = "source" end, function() view.windows[1].zoomed_block_id = nil end)
local _, old_order = geometry.initial(rx, args, bounds, cache)
source.desired[1], source.desired[2] = source.desired[2], source.desired[1]
local _, new_order = geometry.initial(rx, args, bounds, cache)
assert(new_order == old_order, "other clients' row order and timestamps are not geometry")
print("passed: fingerprint invalidation and deterministic client selection")
view.windows[1].zoomed_block_id = "source"
hint = geometry.initial(rx, args, bounds)
assert(hint.columns == 81, "zoomed source already fills the whole viewport")
view.windows[1].zoomed_block_id = nil
view.windows[1].layers[1].bounds = { 0, 0, .5, 1 }
hint = geometry.initial(rx, args, bounds)
assert(hint.columns == 163, "native node rects are already window-relative")
source.owner = "other"
hint = geometry.initial(rx, args, bounds, { cells = { width = 17, height = 55 } })
assert(hint.columns == 163 and hint.rows == 27, "another owner's font cannot establish this app's viewport pixels")
print("passed: zoom, floating geometry, foreign-owner fallback")
local broken = { session = { view = function() error("gone") end }, call = function() return nil, "gone" end }
hint, fingerprint = geometry.initial(broken, args, bounds)
assert(hint.columns > 0 and hint.rows > 0 and fingerprint == nil, "missing source data still provides a seed")
print("passed: missing origin geometry never gates or errors")
local function observer(initial)
  local tick, handle, cancelled, completed, count = nil, nil, 0, nil, 0
  local size = initial or { owner = "cli", columns = 80, rows = 24, cell_width_px = 10, cell_height_px = 30,
    desired = { { client_id = "app", columns = 163, rows = 27 } } }
  local during
  local mock = {
    call = function(method, payload)
      assert(method == "com.superlogical.terminal.size", "observe must never mutate the app")
      assert(payload.block_id == "picker")
      count = count + 1
      if during then during() end
      return size
    end,
    every = function(seconds, callback)
      assert(seconds == .1, "optional cache observation must not poll the app at frame rate"); tick = callback
      return { cancel = function() cancelled = cancelled + 1 end }
    end,
  }
  handle = geometry.observe(mock, args, "picker", function(actual)
    assert(completed == nil, "callback may run only once")
    for key in pairs(actual) do assert(key == "columns" or key == "rows" or key == "cell_width_px" or key == "cell_height_px") end
    completed = actual
  end)
  return { size = size, handle = handle, tick = function() if tick then tick() end end,
    during = function(callback) during = callback end,
    result = function() return completed, cancelled, count end }
end
local o = observer()
local done, cancelled, samples = o.result()
assert(not done and samples == 1, "observe returns after one sample while CLI owns the grid")
o.size.owner = "app"; o.tick()
assert(not o.result(), "ownership alone is insufficient until desired grid matches")
o.size.columns, o.size.rows = 163, 27
o.tick()
done, cancelled, samples = o.result()
assert(done.columns == 163 and done.cell_width_px == 10 and cancelled == 1)
o.tick(); o.handle.cancel()
assert(select(3, o.result()) == samples, "completion/cancellation prevents every later RPC")
print("passed: background ownership observation, final desired grid, callback exactly once")
o = observer({ owner = "app", columns = 100, rows = 30, cell_width_px = 10, cell_height_px = 30,
  desired = { { client_id = "app", columns = 100, rows = 30 } } })
assert(o.result().columns == 100 and select(3, o.result()) == 1, "owned grid is cached immediately")
o = observer()
o.during(function() o.handle.cancel() end)
o.size.owner, o.size.columns, o.size.rows = "app", 163, 27
o.tick()
assert(not o.result(), "cancellation during the size request must prevent its callback")
o = observer()
local real_time, began = os.time, os.time()
os.time = function() return began + 5 end
o.tick()
os.time = real_time
assert(not o.result() and select(2, o.result()) == 1, "timeout silently stops observation")
print("passed: immediate observation, in-flight cancellation, silent bounded timeout")
local clock = 100
os.time = function() return clock end
o = observer()
for tick = 1, 50 do
  clock = 100 + math.floor(tick / 10)
  o.tick()
end
os.time = real_time
assert(not o.result() and select(2, o.result()) == 1 and select(3, o.result()) == 40,
  "an app that never claims ownership must cost at most 40 size samples, including the immediate sample")
print("passed: bounded background RPC budget while app ownership never settles")
local failed = geometry.observe({ call = function() error("pane gone") end,
  every = function() error("must not keep querying a closed pane") end }, args, "picker",
  function() error("missing pane must not callback or create an error UI") end)
failed.cancel()
print("passed: vanished picker is silent")
