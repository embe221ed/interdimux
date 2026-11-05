-- Coalesce native changes without polling the server while the picker is idle.
local M = {}
local structural = { session_view_changed = true, session_created = true,
  session_destroyed = true, block_closed = true }
local terminal = { ["terminal.process_changed"] = true, ["terminal.pwd_changed"] = true,
  ["terminal.title_changed"] = true, ["terminal.progress_report"] = true,
  ["terminal.program_status_changed"] = true, ["terminal.program_status_removed"] = true,
  ["terminal.child_exited"] = true }
M.events = { "session_view_changed", "session_created", "session_destroyed", "block_closed",
  "terminal.process_changed", "terminal.pwd_changed", "terminal.title_changed",
  "terminal.progress_report", "terminal.program_status_changed", "terminal.program_status_removed",
  "terminal.child_exited" }

function M.new(rx, args, refresh)
  local timer, stopped, ready = nil, false, false
  local revisions, sessions, blocks = {}, {}, {}
  local function cancel_timer()
    if timer then timer:cancel(); timer = nil end
  end
  local function changed(name, ctx, event)
    if stopped or not ready or not (structural[name] or terminal[name]) then return end
    event, ctx = event or {}, ctx or {}
    local block_id = event.block_id or ctx.block_id
    if block_id and block_id == args.picker_block_id then return end
    local session_id = event.session_id or ctx.session_id
      or (type(event.session) == "table" and event.session.session_id)
    if structural[name] then
      if not session_id then return end
      if name == "session_view_changed" and type(event.revision) == "number"
          and event.revision <= (revisions[session_id] or -1) then return end
      sessions[session_id] = true
    else
      if not block_id then return end
      blocks[block_id] = true
    end
    if timer then return end
    -- A fixed window coalesces bursts without starving updates under a
    -- continuous progress stream. Native callbacks run serially in Rex.
    timer = rx.after(.25, function()
      timer = nil
      if stopped then return end
      local changes = { sessions = sessions, blocks = blocks }
      sessions, blocks = {}, {}
      local ok, err = pcall(refresh, changes)
      if not ok then
        -- Keep the last valid snapshot. Retry these dirty IDs with the next
        -- event, without an idle retry loop or a terminal error overlay.
        for id in pairs(changes.sessions) do sessions[id] = true end
        for id in pairs(changes.blocks) do blocks[id] = true end
        rx.log("error", "interdimux live refresh: " .. tostring(err))
      end
    end)
  end
  return {
    changed = changed,
    update = function(snapshot)
      if stopped then return end
      revisions = {}
      for id, view in pairs(snapshot.views or {}) do
        if type(view) == "table" and type(view.revision) == "number" then revisions[id] = view.revision end
      end
      sessions, blocks = {}, {}
      cancel_timer()
      ready = true
    end,
    cancel = function()
      stopped = true
      cancel_timer()
      sessions, blocks = {}, {}
    end,
  }
end
return M
