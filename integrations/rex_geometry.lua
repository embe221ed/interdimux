-- Seed immediately; observe the app's final grid only to improve the cache.
-- Source font metrics describe a viewport, never a desired picker font.
local M = {}
local function positive(v)
  return type(v) == "number" and v > 0 and v < math.huge
end
local function grid(v, fallback)
  if not positive(v) then return fallback end
  return math.max(1, math.min(65535, math.floor(v)))
end
local function rect(v)
  if type(v) ~= "table" or not positive(v[3]) or not positive(v[4]) then return nil end
  return { tonumber(v[1]) or 0, tonumber(v[2]) or 0, v[3], v[4] }
end
local function block_rect(node, id)
  if type(node) ~= "table" then return nil end
  if node.block_id == id then return rect(node.rect) end
  if type(node.split) == "table" then
    return block_rect(node.split.before, id) or block_rect(node.split.after, id)
  end
end
local function source_rect(view, args)
  for _, window in ipairs(type(view) == "table" and view.windows or {}) do
    if window.window_id == args.window_id then
      if window.zoomed_block_id == args.block_id then return { 0, 0, 1, 1 } end
      for _, layer in ipairs(window.layers or {}) do
        -- The installed API defines node rects as fractions of the window,
        -- including floating layers. Multiplying by layer bounds doubles it.
        local found = block_rect(layer.layout, args.block_id)
        if found then return found end
      end
    end
  end
end
local function copy_size(size)
  if type(size) ~= "table" or not positive(size.columns) or not positive(size.rows) then return nil end
  local out = { columns = grid(size.columns), rows = grid(size.rows) }
  if positive(size.cell_width_px) and positive(size.cell_height_px) then
    out.cell_width_px, out.cell_height_px = size.cell_width_px, size.cell_height_px
  end
  return out
end
local function desired_for(size, client)
  for _, desired in ipairs(size.desired or {}) do
    if desired.client_id == client and positive(desired.columns) and positive(desired.rows) then return desired end
  end
end
function M.initial(rx, args, bounds, cache)
  args = args or {}
  cache = type(cache) == "table" and cache or {}
  bounds = rect(bounds) or { .11, .17, .78, .66 }
  local viewed, view = pcall(function() return rx.session.view { session_id = args.session_id } end)
  local sampled, size = pcall(function()
    return rx.call("com.superlogical.terminal.size", {
      session_id = args.session_id, block_id = args.block_id, args = {},
    })
  end)
  if not sampled or type(size) ~= "table" then size = {} end
  local source = viewed and source_rect(view, args)
  local desired = desired_for(size, args.client_id)
  local columns = grid(desired and desired.columns or size.columns, 80)
  local rows = grid(desired and desired.rows or size.rows, 24)
  local cells = type(cache.cells) == "table" and cache.cells or {}
  local cached_cells = positive(cells.width) and positive(cells.height)
  local fingerprint
  if source and positive(size.columns) and positive(size.rows) then
    local fields = { "geometry-v1", args.client_id or "", args.session_id or "",
      args.window_id or "", args.block_id or "", size.owner or "" }
    local function add(v)
      fields[#fields + 1] = type(v) == "number" and string.format("%.12g", v) or tostring(v or "")
    end
    for i = 1, 4 do add(bounds[i]) end
    for i = 1, 4 do add(source[i]) end
    add(size.columns); add(size.rows)
    add(desired and desired.columns); add(desired and desired.rows)
    add(size.cell_width_px); add(size.cell_height_px)
    fingerprint = table.concat(fields, "|")
    local entry = type(cache.windows) == "table" and cache.windows[args.window_id]
    if type(entry) == "table" and entry.fingerprint == fingerprint then
      local exact = copy_size(entry.size)
      if exact then return exact, fingerprint end
    end
  end
  local fraction = source or { 0, 0, 1, 1 }
  local width, height = columns * bounds[3] / fraction[3], rows * bounds[4] / fraction[4]
  if cached_cells and size.owner == args.client_id
      and positive(size.cell_width_px) and positive(size.cell_height_px) then
    width, height = width * size.cell_width_px / cells.width, height * size.cell_height_px / cells.height
  end
  local hint = { columns = grid(width, 80), rows = grid(height, 24) }
  if cached_cells then hint.cell_width_px, hint.cell_height_px = cells.width, cells.height end
  return hint, fingerprint
end
function M.observe(rx, args, picker, callback)
  local timer
  local done, busy = false, false
  local began = os.time()
  local function cancel()
    if done then return end
    done = true
    if timer then timer:cancel() end
  end
  local function expired()
    if done then return true end
    if os.time() - began >= 4 then cancel(); return true end
    return false
  end
  local function sample()
    if busy or expired() then return end
    busy = true
    local ok, size = pcall(function()
      return rx.call("com.superlogical.terminal.size", {
        session_id = args.session_id, block_id = picker, args = {},
      })
    end)
    busy = false
    if expired() then return end
    if not ok or type(size) ~= "table" then cancel(); return end
    local desired = desired_for(size, args.client_id)
    if size.owner ~= args.client_id or not desired
        or desired.columns ~= size.columns or desired.rows ~= size.rows
        or not positive(size.cell_width_px) or not positive(size.cell_height_px) then return end
    local actual = copy_size(size)
    if actual then
      cancel()
      -- A cache persistence failure must never affect the running picker.
      pcall(callback, actual)
    end
  end
  sample()
  -- This learns a future opening's grid; it never resizes or gates this picker.
  -- A slow/disconnected app therefore needs at most about 40 background RPCs
  -- over the observation window instead of polling its ownership at 50 Hz.
  if not done then timer = rx.every(.1, sample) end
  return { cancel = cancel }
end
return M
