-- Only read the layout needed for remote navigation. Terminal screen content
-- and per-pane process details are unnecessary for indexing the layout.
local args = rex.args
local sessions = args.session_ids
local batch, err = rex.call("session.bootstrap", {
  event_scope = "session", attach_session_ids = sessions,
})
local host_id
if batch then
  host_id = batch.server_status and batch.server_status.host_id
else
  -- Older servers expose individual views. Only fall back on an unsupported
  -- bootstrap API. A transport or permission failure should end this refresh.
  local reason = tostring(err)
  if not reason:find("code=method_not_found", 1, true)
      and not reason:find('unknown field "attach_session_ids"', 1, true) then
    error(err, 0)
  end
  local status, status_error = rex.call("server.status", {})
  if not status then error(status_error, 0) end
  host_id = status.host_id
end
if not host_id or host_id ~= args.host_id then error("The Rex host changed.", 0) end

-- A terminal called interdimux could also be an ordinary user pane. Verify
-- the executable only for the possible picker panes before omitting them.
local function picker_block(session_id, block)
  if block.label ~= "interdimux" or block.creator_name ~= "com.superlogical.terminal" then
    return false
  end
  local process = rex.call("com.superlogical.terminal.process", {
    session_id = session_id, block_id = block.block_id, args = {},
  })
  local child = process and process.child
  if not child then return false end
  local executable = child.path or child.invoked_path or child.argv0 or child.name or ""
  return executable:gsub(" %(deleted%)$", ""):match("[^/]+$") == "imux"
end

local layouts = {}
local function collect(session_id, view)
  if not session_id or not view or view.session_id ~= session_id then return end
  local windows = {}
  for _, window in ipairs(view.windows or {}) do
    local panes = {}
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if not picker_block(session_id, block) then
          panes[#panes + 1] = {
            block_id = block.block_id,
            label = block.label,
            title = block.title,
            cwd = block.cwd,
            terminal = block.creator_name == "com.superlogical.terminal",
            focused = block.block_id == window.focused_block_id,
          }
        end
      end
    end
    windows[#windows + 1] = {
      window_id = window.window_id,
      label = window.label,
      active = window.window_id == view.active_window_id,
      panes = panes,
    }
  end
  layouts[session_id] = windows
end

if batch then
  for _, entry in ipairs(batch.attached_sessions or {}) do
    collect(entry.session and entry.session.session_id, entry.view)
  end
else
  local attached, attach_error = rex.call("session.attach_all", { event_scope = "session" })
  if not attached then error(attach_error, 0) end
  for _, session_id in ipairs(sessions) do
    collect(session_id, rex.session.view { session_id = session_id })
  end
end
return { host_id = host_id, layouts = layouts }
