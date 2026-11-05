-- Loaded by the native coordinator or embedded in imux's direct CLI fallback.
-- Selection is strictly scoped by the CLI. Cancellation is
-- best effort: an origin closed while filtering must not strand an error float.
return function(args)
if args.restore then
  local listed, list_err = rex.call("session.attach_all", { event_scope = "session" })
  if listed == nil then error(list_err, 0) end
  local session_found = false
  for _, session in ipairs(listed.sessions or {}) do
    if session.session_id == args.session_id then session_found = true end
  end
  if not session_found then return end
end
local view, err = rex.session.view{ session_id = args.session_id }
if view == nil then
  if args.restore then return end
  error(err, 0)
end

-- A persistent picker may have swapped the origin into another window.
-- Cancellation follows that exact block; ordinary selections remain strict.
if args.restore and args.block_id then
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == args.block_id then args.window_id = window.window_id end
      end
    end
  end
end

local window_found = args.window_id == nil
local block_found = args.block_id == nil
local zoom_found = false
for _, window in ipairs(view.windows or {}) do
  if args.window_id == nil or window.window_id == args.window_id then
    window_found = true
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == args.block_id then block_found = true end
        if block.block_id == args.origin_zoomed_block_id then zoom_found = true end
      end
    end
  end
end
if not window_found then
  if args.restore then return end
  error("The selected Rex window no longer exists", 0)
end
if not block_found then
  if args.restore then return end
  error("The selected Rex pane no longer exists", 0)
end

if args.block_id ~= nil then
  local focused, focus_err = rex.session.focus_block{
    session_id = args.session_id, block_id = args.block_id,
  }
  if focused == nil then
    if args.restore then return end
    error(focus_err, 0)
  end
elseif args.window_id ~= nil then
  local focused, focus_err = rex.session.focus_window{
    session_id = args.session_id, window_id = args.window_id,
  }
  if focused == nil then
    if args.restore then return end
    error(focus_err, 0)
  end
end

local selection = { session_id = args.session_id }
if args.window_id ~= nil then selection.window_id = args.window_id end
local performed, perform_err = rex.call("client.perform", {
  client_id = args.client_id,
  action = "session.select",
  args = selection,
  origin = "cli",
  timeout_ms = 5000,
})
if performed == nil then error(perform_err, 0) end

-- Successful navigation must never inherit the old pane's zoom state.
if args.restore and args.origin_zoomed_block_id ~= nil and zoom_found then
  rex.session.zoom_block{
    session_id = args.session_id,
    block_id = args.origin_zoomed_block_id,
    zoom = true,
  }
end
end
