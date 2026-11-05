-- Runs outside the picker terminal. Closing that terminal cannot kill this
-- connection, so completion never depends on a caller surviving its own close.
local args = rex.args
local root = assert(args.root, "missing interdimux checkout root")
local activate = dofile(root .. "/rust/src/rex_activate.lua")
local operate = dofile(root .. "/integrations/rex_operations.lua")
local geometry = dofile(root .. "/integrations/rex_geometry.lua")
local event_updates = dofile(root .. "/integrations/rex_events.lua")
local directory, snapshot_path, result_path
local request_path, response_path, ready_path, mailbox_timer, geometry_timer
local live_path, live_updates, latest_snapshot
args.live_refresh = os.getenv("INTERDIMUX_LIVE_REFRESH") ~= "off"
local last_request = 0
local operation_context = {}
for key, value in pairs(args) do operation_context[key] = value end
operation_context.hosted = true
local history, history_path
local grid_cache, grid_path, grid_parent, grid_fingerprint
local picker_block, picker_layer
local notice_block, notice_layer
local notice_waiting = false
local finish_notice
local pending = {}
local finished = false
local bounds = args.bounds or { 0.11, 0.17, 0.78, 0.66 }
local writes = 0

local function atomic_json(path, value)
  local temporary = path .. ".tmp"
  if directory and path:sub(1, #directory + 1) ~= directory .. "/" then
    writes = writes + 1
    temporary = path .. ".tmp-" .. directory:match("([^/]+)$") .. "-" .. writes
  end
  local file, open_error = io.open(temporary, "wb")
  if not file then error(open_error, 0) end
  local ok, write_error = pcall(function()
    assert(file:write(rex.json.encode(value)))
    assert(file:close())
  end)
  if not ok then pcall(function() file:close() end); os.remove(temporary); error(write_error, 0) end
  local renamed, rename_error = os.rename(temporary, path)
  if not renamed then os.remove(temporary); error(rename_error, 0) end
end

local function load_grid()
  local parent = os.getenv("XDG_STATE_HOME")
  if not parent or parent == "" then
    local home = os.getenv("HOME")
    if not home or home == "" then return {} end
    parent = home .. "/.local/state"
  end
  grid_parent = parent .. "/interdimux"
  grid_path = grid_parent .. "/rex-picker-" .. args.client_id:gsub("[^%w_-]", "_") .. ".json"
  local file = io.open(grid_path, "rb")
  if file then
    local text = file:read("*a"); file:close()
    local decoded, value = pcall(rex.json.decode, text)
    if decoded and type(value) == "table" and value.version == 1
        and type(value.windows) == "table" then return value end
  end
  return { version = 1, windows = {} }
end

local function remember_grid(size)
  if finished or not grid_path then return end
  grid_cache.cells = { width = size.cell_width_px, height = size.cell_height_px }
  if grid_fingerprint then
    grid_cache.windows[args.window_id] = {
      fingerprint = grid_fingerprint, size = size, used = os.time(),
    }
  end
  local entries = {}
  for key, value in pairs(grid_cache.windows) do
    entries[#entries + 1] = { key = key, used = type(value) == "table" and tonumber(value.used) or 0 }
  end
  table.sort(entries, function(a, b) return (a.used or 0) > (b.used or 0) end)
  for index = 65, #entries do grid_cache.windows[entries[index].key] = nil end
  if not os.rename(grid_parent, grid_parent) then
    local made = rex.exec { "mkdir", "-p", grid_parent }
    if not made or not made.ok or finished then return end
  end
  local written, write_error = pcall(atomic_json, grid_path, grid_cache)
  if not written then rex.log("error", "interdimux picker size cache: " .. tostring(write_error)) end
end

local function merge_history()
  if not history_path then return end
  local file = io.open(history_path, "rb")
  if not file then return end
  local text = file:read(2097153); file:close()
  if not text or #text > 2097152 then return end
  local decoded, latest = pcall(rex.json.decode, text)
  if not decoded or type(latest) ~= "table" or latest.version ~= 1
      or type(latest.sessions) ~= "table" then return end
  history.last = math.max(tonumber(history.last) or 0, tonumber(latest.last) or 0)
  for session_id, stamp in pairs(latest.sessions) do
    if type(session_id) == "string" and type(stamp) == "number"
        and stamp > (tonumber(history.sessions[session_id]) or 0) then
      history.sessions[session_id] = stamp
    end
  end
  for session_id, path in pairs(type(latest.paths) == "table" and latest.paths or {}) do
    if type(session_id) == "string" and type(path) == "string" then history.paths[session_id] = path end
  end
end

local function remember(session_id, already_loaded)
  if not history or not session_id then return end
  if not already_loaded then merge_history() end
  history.last = math.max(os.time(), (tonumber(history.last) or 0) + 1)
  history.sessions[session_id] = history.last
  local stored, store_error = pcall(atomic_json, history_path, history)
  if not stored then rex.log("error", "interdimux MRU: " .. tostring(store_error)) end
end

local function load_history(snapshot)
  -- Hosted snapshots prove the coordinator and picker share the server's home.
  if not snapshot.host_id then return end
  local home = os.getenv("HOME")
  if not home or home == "" then return end
  local state = os.getenv("XDG_STATE_HOME")
  if not state or state == "" then state = home .. "/.local/state" end
  local parent = state .. "/interdimux"
  local exists = os.rename(parent, parent)
  if not exists then
    local created = rex.exec { "mkdir", "-p", parent }
    if not created or not created.ok then return end
  end
  history_path = parent .. "/rex-mru.json"
  local file = io.open(history_path, "rb")
  if file then
    local text = file:read("*a"); file:close()
    local ok, parsed = pcall(rex.json.decode, text)
    if ok and type(parsed) == "table" and parsed.version == 1 and type(parsed.sessions) == "table" then history = parsed end
  end
  if not history then history = { version = 1, last = 0, sessions = {} } end
  if type(history.paths) ~= "table" then history.paths = {} end
  local existing = {}
  for _, session in ipairs(snapshot.sessions or {}) do existing[session.session_id] = true end
  for session_id in pairs(history.sessions) do
    if not existing[session_id] then history.sessions[session_id] = nil end
  end
  for session_id in pairs(history.paths) do
    if not existing[session_id] then history.paths[session_id] = nil end
  end
  -- The just-loaded file is already current. Avoid a second first-frame read.
  remember(args.session_id, true)
end

local function collect_snapshot(changes)
  args.live_previous_snapshot = changes and latest_snapshot
  args.live_dirty_sessions = changes and changes.sessions
  args.live_dirty_blocks = changes and changes.blocks
  local ok, snapshot = pcall(dofile, root .. "/rust/src/rex_snapshot.lua")
  args.live_previous_snapshot = nil
  args.live_dirty_sessions = nil
  args.live_dirty_blocks = nil
  if not ok then error(snapshot, 0) end
  return snapshot
end

local function save_snapshot(changes)
  local snapshot = collect_snapshot(changes)
  if history then snapshot.mru = history.sessions; snapshot.session_paths = history.paths end
  atomic_json(snapshot_path, snapshot)
  latest_snapshot = snapshot
  if live_updates then live_updates.update(snapshot) end
end

local function clean()
  if mailbox_timer then mailbox_timer:cancel() end
  if geometry_timer then geometry_timer:cancel() end
  if live_updates then live_updates.cancel() end
  if live_path then os.remove(live_path); os.remove(live_path .. ".tmp") end
  if ready_path then os.remove(ready_path); os.remove(ready_path .. ".tmp") end
  if request_path then os.remove(request_path); os.remove(request_path .. ".tmp") end
  if response_path then os.remove(response_path); os.remove(response_path .. ".tmp") end
  if result_path then
    os.remove(result_path .. ".tmp")
    os.remove(result_path)
  end
  if snapshot_path then os.remove(snapshot_path) end
  if directory then
    -- A manual native close can terminate Rust before its Drop runs.
    os.remove(directory .. "/ui/c")
    os.remove(directory .. "/ui/f.sock")
    os.remove(directory .. "/ui")
    os.remove(directory)
  end
end

local function close_picker()
  if picker_layer then
    -- Successful program exit may already have removed the empty layer.
    rex.session.close_layer { session_id = args.session_id, layer_id = picker_layer }
  end
end

local function notice(message)
  message = tostring(message)
  rex.log("error", "interdimux: " .. message)
  -- Preparation may have failed before subscribing to the origin session.
  local observed, observe_error = rex.session.attach { session_id = args.session_id }
  if not observed then
    rex.log("error", "interdimux could not observe its error: " .. tostring(observe_error))
    return
  end
  -- Failure is exceptional. Keep it readable without starting a login shell
  -- or interpolating the message as shell code.
  local shown, show_error = rex.session.new_layer {
    session_id = args.session_id, window_id = args.window_id,
    bounds = bounds, focus = true,
    layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell", label = "interdimux error",
      options = {
        shell = "none", login = false,
        command = { "/bin/sh", "-c",
          "printf 'interdimux: %s\\n\\nPress Enter to close. ' \"$1\"; IFS= read -r reply",
          "interdimux", (message:gsub("[%z\1-\8\11-\31\127]", "")) },
        exit = { on_completion = true, quick_exit_threshold_ms = 0 },
      },
    },
  }
  if not shown then
    rex.log("error", "interdimux could not show its error: " .. tostring(show_error))
    return
  end
  notice_layer = shown.layer_id
  notice_block = shown.block_ids[1]
  notice_waiting = true
  rex.session.disown_block { session_id = args.session_id, block_ids = { notice_block } }
end

local function read_result()
  if not result_path then return nil end
  local file = io.open(result_path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  local decoded, result = pcall(rex.json.decode, text)
  if not decoded or type(result) ~= "table" or result.version ~= 1 then
    error("The picker returned an invalid completion record", 0)
  end
  return result
end

local function restore()
  activate {
    client_id = args.client_id, session_id = args.session_id,
    window_id = args.window_id, block_id = args.block_id,
    restore = true, origin_zoomed_block_id = args.origin_zoomed_block_id,
  }
end

finish_notice = function()
  if not notice_waiting then return end
  notice_waiting = false
  rex.session.close_layer { session_id = args.session_id, layer_id = notice_layer }
  local restored, restore_error = pcall(restore)
  if not restored then rex.log("error", "interdimux could not restore its origin: " .. tostring(restore_error)) end
  clean()
  rex.stop(1)
end

local function wait_notice_or_stop(status)
  if notice_waiting then
    if pending[notice_block] then finish_notice() end
  else
    rex.stop(status)
  end
end

local function complete(kind, event)
  if finished then return end
  finished = true
  local ok, completion_error = pcall(function()
    local result = read_result()
    -- Close first, using this independent connection, and only then navigate.
    close_picker()
    if not result then
      if kind == "closed" then restore(); return end -- Closed manually in Rex.
      error("The picker exited without returning a selection (status " .. tostring(event.exit_code) .. ")", 0)
    end
    if result.outcome == "cancel" then
      restore()
    elseif result.outcome == "select" then
      local target = result.target
      if type(target) ~= "table" or type(target.session_id) ~= "string" then
        error("The picker returned an invalid target", 0)
      end
      activate {
        client_id = args.client_id, session_id = target.session_id,
        window_id = target.window_id, block_id = target.block_id,
      }
      remember(target.session_id)
    elseif result.outcome == "action" then
      local context = {}
      for key, value in pairs(operation_context) do context[key] = value end
      context.finished = true
      operate({ operation = result.operation, target = result.target, args = result.args or {} }, context)
      if result.operation == "close" then
        local listed = rex.call("session.attach_all", { event_scope = "session" })
        local fallback
        for _, session in ipairs(listed and listed.sessions or {}) do
          local view = rex.session.view { session_id = session.session_id }
          if view and view.windows and #view.windows > 0 then
            local candidate = { session_id = session.session_id, window_id = view.active_window_id }
            if not fallback or session.session_id == args.session_id then fallback = candidate end
          end
        end
        if fallback then
          local selected, selection_error = rex.call("client.perform", {
            client_id = args.client_id, action = "session.select", args = fallback,
            origin = "cli", timeout_ms = 5000,
          })
          if not selected then error(selection_error, 0) end
          remember(fallback.session_id)
        end
      elseif result.target then remember(result.target.session_id) end
    elseif result.outcome == "error" then
      -- The error was acknowledged in Rust; this is dismissal, like cancel.
      restore()
    else
      error("The picker returned an unknown completion outcome", 0)
    end
  end)
  if not ok then
    close_picker()
    local reported, report_error = pcall(notice, completion_error)
    if not reported then rex.log("error", tostring(report_error)) end
  end
  clean()
  wait_notice_or_stop(ok and 0 or 1)
end

local function exited(kind, event)
  if notice_waiting and event.block_id == notice_block then finish_notice(); return end
  if finished then
    -- Notice creation can itself race an immediate dismissal.
    if not notice_block then pending[event.block_id] = { kind, event } end
    return
  end
  if not picker_block then pending[event.block_id] = { kind, event }; return end
  if event.block_id == picker_block then complete(kind, event) end
end

local function prepare()
  local temporary, temporary_error = rex.exec {
    "mktemp", "-d", (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/interdimux-rex.XXXXXX",
  }
  if not temporary then error(temporary_error, 0) end
  if not temporary.ok then error(temporary.stderr, 0) end
  directory = temporary.stdout:gsub("[\r\n]+$", "")
  snapshot_path = directory .. "/snapshot.json"
  result_path = directory .. "/result.json"
  request_path = directory .. "/request.json"
  response_path = directory .. "/response.json"
  ready_path = directory .. "/ready.json"
  if args.live_refresh then live_path = directory .. "/live.json" end
  -- attach_all(session) omits terminal events. Join just the origin session
  -- before creating the terminal, so even a very fast child exit is observed.
  local observed, observe_error = rex.session.attach { session_id = args.session_id }
  if not observed then error(observe_error, 0) end
  grid_cache = load_grid()
  local size
  size, grid_fingerprint = geometry.initial(rex, args, bounds, grid_cache)
  -- Snapshot publication alone gates the child. GUI ownership and font changes
  -- must never delay the first frame; seed the expected grid before spawning.
  atomic_json(ready_path, { version = 1, ready = false })

  local command = {
    args.binary, "pick", "--backend", "rex",
    "--client", args.client_id, "--session", args.session_id,
    "--window", args.window_id, "--block", args.block_id,
    "--snapshot", snapshot_path, "--result", result_path,
  }
  if args.origin_zoomed_block_id then
    command[#command + 1] = "--origin-zoom"
    command[#command + 1] = args.origin_zoomed_block_id
  end
  if args.mode and args.mode ~= "switch" then
    command[#command + 1] = "--mode"
    command[#command + 1] = args.mode
  end
  local created, create_error = rex.session.new_layer {
    session_id = args.session_id, window_id = args.window_id,
    bounds = bounds, focus = true,
    layout = rex.layout.block {
      flavor = "com.superlogical.terminal.shell", label = "interdimux",
      options = {
        shell = "none", login = false, command = command, cwd = root, size = size,
        path_prepend = { "/opt/homebrew/bin", "/usr/local/bin" },
        exit = { on_completion = true, quick_exit_threshold_ms = 0 },
      },
    },
  }
  if not created then error(create_error, 0) end
  picker_layer = created.layer_id
  picker_block = created.block_ids[1]
  operation_context.picker_block_id = picker_block
  -- The observing CLI must not hold the terminal size at its initial 80x24.
  -- Hand ownership to the app (or leave it unowned until the app requests it).
  rex.session.disown_block { session_id = args.session_id, block_ids = { picker_block } }
  if finished then return end
  -- Let the GUI claim/size the float while collecting metadata. The child
  -- waits on ready.json only until the snapshot is complete. Avoid querying
  -- the picker's own process.
  args.picker_block_id = picker_block
  local snapshot = collect_snapshot()
  if finished then return end
  load_history(snapshot)
  if finished then return end
  if history then snapshot.mru = history.sessions; snapshot.session_paths = history.paths end
  atomic_json(snapshot_path, snapshot)
  latest_snapshot = snapshot
  if live_updates then
    live_updates.update(snapshot)
    atomic_json(live_path, { version = 1 })
  end
  atomic_json(ready_path, { version = 1, ready = true })
  -- Learn exact default-font metrics and the resulting grid after rendering.
  -- This observation is optional and cannot keep the picker waiting.
  geometry_timer = geometry.observe(rex, args, picker_block, remember_grid)
  mailbox_timer = rex.every(0.02, function()
    if finished then return end
    local file = io.open(request_path, "rb")
    if not file then return end
    local text = file:read("*a"); file:close()
    local decoded, request = pcall(rex.json.decode, text)
    if not decoded or type(request) ~= "table" or request.version ~= 1
        or type(request.id) ~= "number" or request.id <= last_request then return end
    last_request = request.id
    -- The worker may publish its next request as soon as it reads our reply.
    -- Remove this request before any response can acknowledge it.
    os.remove(request_path)
    local ok, data = pcall(operate, request, operation_context)
    if ok and history and request.operation == "create" and request.args
        and (not request.args.kind or request.args.kind == "session")
        and type(request.args.cwd) == "string" and data.target then
      merge_history()
      history.paths[data.target.session_id] = request.args.cwd
      local stored, store_error = pcall(atomic_json, history_path, history)
      if not stored then rex.log("error", tostring(store_error)) end
    end
    -- These queries do not change the tree. Recollecting every session and
    -- terminal here makes health checks and scheduling pay for an unrelated
    -- full refresh before the request can return.
    if request.operation ~= "preview" and request.operation ~= "health"
        and request.operation ~= "schedule-target" then
      local refreshed, refresh_error = pcall(save_snapshot)
      if not refreshed and ok then ok, data = false, refresh_error end
    end
    local response = { version = 1, id = request.id, ok = ok }
    if ok then response.data = data else response.error = tostring(data) end
    local written, write_error = pcall(atomic_json, response_path, response)
    if not written then rex.log("error", "interdimux response: " .. tostring(write_error)) end
  end)
end

-- Register before preparation so even its exceptional notice has an owned
-- lifecycle, rather than outliving the coordinator and losing saved zoom.
if args.live_refresh then
  live_updates = event_updates.new(rex, args, save_snapshot)
  for _, name in ipairs(event_updates.events) do
    if name ~= "terminal.child_exited" and name ~= "block_closed" and name ~= "session_destroyed" then
      rex.on(name, function(ctx, event) live_updates.changed(name, ctx, event) end)
    end
  end
end
rex.on("terminal.child_exited", function(ctx, event)
  if live_updates then live_updates.changed("terminal.child_exited", ctx, event) end
  exited("child", event)
end)
rex.on("block_closed", function(ctx, event)
  if live_updates then live_updates.changed("block_closed", ctx, event) end
  exited("closed", event)
end)
rex.on("session_destroyed", function(ctx, event)
  if event.session_id == args.session_id and not finished then
    finished = true
    clean()
    rex.stop()
  elseif live_updates then
    live_updates.changed("session_destroyed", ctx, event)
  end
end)

local prepared, prepare_error = pcall(prepare)
if not prepared then
  finished = true
  close_picker()
  local reported, report_error = pcall(notice, prepare_error)
  if not reported then rex.log("error", tostring(report_error)) end
  clean()
  wait_notice_or_stop(1)
elseif pending[picker_block] then
  complete(pending[picker_block][1], pending[picker_block][2])
end
