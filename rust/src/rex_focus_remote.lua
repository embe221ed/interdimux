local target = rex.args

local function call(method, args)
  local value, err = rex.call(method, args)
  if value == nil then error(err, 0) end
  return value
end

-- Bootstrap gets the server identity and this session's exact view in one RPC.
-- Older servers can still provide the two pieces separately.
local opened, err = rex.call("session.bootstrap", {
  event_scope = "session", attach_session_ids = { target.session_id },
})
local status, view
if opened then
  status = opened.server_status
  for _, entry in ipairs(opened.attached_sessions or {}) do
    if entry.view and entry.view.session_id == target.session_id then view = entry.view; break end
  end
else
  local reason = tostring(err)
  if not reason:find("code=method_not_found", 1, true)
      and not reason:find('unknown field "attach_session_ids"', 1, true) then
    error(err, 0)
  end
  status = call("server.status", {})
end
if not status or status.host_id ~= target.host_id then
  error("The Rex host changed. Refresh the picker before switching.", 0)
end

local pane_missing = "The selected Rex pane moved or closed. Refresh the picker."
local function check_view(view)
  if not view or view.session_id ~= target.session_id then
    error("The selected Rex session no longer exists. Refresh the picker.", 0)
  end
  for _, window in ipairs(view.windows or {}) do
    if window.window_id == target.window_id then
      if not target.block_id then return end
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == target.block_id then return end
        end
      end
      error(pane_missing, 0)
    end
  end
  error("The selected Rex tab no longer exists. Refresh the picker.", 0)
end
if not opened then view = call("session.attach", { session_id = target.session_id }).view end
check_view(view)

local revealed, reveal_error = rex.exec(target.reveal, { timeout = 13 })
if not revealed then error(reveal_error, 0) end
if not revealed.ok then
  error(revealed.stderr ~= "" and revealed.stderr or "Could not show the selected Rex session.", 0)
end

-- Showing the session can restore the app's old responder. Set focus after
-- reveal. A pane can move in the meantime, so verify its current placement.
local function focus()
  if target.block_id then
    local found, err = rex.call("target.resolve", {
      kinds = {"block"}, queries = {target.block_id},
      scope = { session = target.session_id, window = target.window_id },
    })
    if found then
      local result = (found.results or {})[1]
      local pane = result and result.status == "resolved" and result.target
      if not pane or pane.session_id ~= target.session_id or pane.window_id ~= target.window_id
          or pane.block_id ~= target.block_id then
        error(pane_missing, 0)
      end
    elseif tostring(err):find("code=method_not_found", 1, true) then
      check_view(call("session.attach", { session_id = target.session_id }).view)
    else
      error(err, 0)
    end
    return call("session.focus_block", { session_id = target.session_id, block_id = target.block_id })
  end
  return call("session.focus_window", { session_id = target.session_id, window_id = target.window_id })
end

local ok, focus_error = pcall(focus)
if not ok then error("The session opened, but Rex could not focus the selection: " .. tostring(focus_error), 0) end
return { focused = true }
