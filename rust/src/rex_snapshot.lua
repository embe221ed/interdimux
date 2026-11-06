-- Embedded in imux. One CLI process and connection; no per-session process.
local args = rex.args or {}
-- Numbered jumps need only labels and MRU; avoid attaching to or inspecting
-- every session's terminals just to select a session ID.
local listed, err
if args.sessions_only then
  listed, err = rex.call("session.list", {})
else
  listed, err = rex.call("session.attach_all", {
    event_scope = args.live_refresh and "all" or "session",
  })
end
if listed == nil then error(err, 0) end

local views = {}
local errors = {}
local metadata = {}
local incomplete_metadata = {}
local picker_block_id = args.picker_block_id
-- The hosted event observer supplies a complete prior snapshot and exact dirty
-- IDs. Ordinary refreshes deliberately omit these arguments and collect fresh
-- data. Never cache a failed metadata request or a missing session view.
-- Partial reads still supply useful metadata, but retry with the next native
-- event's collection instead of treating missing title/status as a clean hit.
local previous = args.live_previous_snapshot
if type(previous) ~= "table" or previous.version ~= 1
    or type(previous.views) ~= "table" or type(previous.metadata) ~= "table"
    or type(args.live_dirty_blocks) ~= "table" or type(args.live_dirty_sessions) ~= "table" then
  previous = nil
end
local status = rex.call("server.status", {})
-- Standalone collection can prove its CLI is a local Unix peer. The Rust
-- parent supplies the actual child PID/UID in this embedded script; remote
-- transports (or forwarded peers with a different process) get no proof.
local local_host_id
if imux_collector_pid and imux_collector_uid then
  local identity = rex.call("server.whoami", {})
  local principal = identity and identity.principal
  if principal and principal.kind == "peer" and principal.transport == "unix"
      and (principal.path == nil or (type(principal.path) == "table" and next(principal.path) == nil))
      and principal.pid == imux_collector_pid and principal.uid == imux_collector_uid then
    local_host_id = status and status.host_id
  end
end
for _, session in ipairs(not args.sessions_only and listed.sessions or {}) do
  local session_id = session.session_id
  local session_dirty = not previous or args.live_dirty_sessions[session_id]
  local view = not session_dirty and previous.views[session_id] or nil
  local view_err
  if view == nil then
    session_dirty = true
    view, view_err = rex.session.view{ session_id = session_id }
  end
  if view ~= nil then
    views[session.session_id] = view
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.creator_name == "com.superlogical.terminal"
              and block.block_id ~= picker_block_id then
            -- Layout changes do not invalidate terminal process metadata.
            -- New blocks have no cache; terminal events explicitly dirty IDs.
            local cached = previous and not args.live_dirty_blocks[block.block_id]
              and not (type(previous.incomplete_metadata) == "table"
                and previous.incomplete_metadata[block.block_id])
              and previous.metadata[block.block_id]
            if cached then
              metadata[block.block_id] = cached
            else
              local process = rex.call("com.superlogical.terminal.process", {
                session_id = session.session_id, block_id = block.block_id, args = {},
              })
              if process ~= nil then
                if os.getenv("INTERDIMUX_SHOW_TITLE") ~= "off" then
                  local title = rex.call("com.superlogical.terminal.title", {
                    session_id = session.session_id, block_id = block.block_id, args = {},
                  })
                  if title then
                    process.title = title.title; process.title_owner = title.owner
                  else
                    incomplete_metadata[block.block_id] = true
                  end
                end
                if os.getenv("INTERDIMUX_AGENT_STATE") ~= "off"
                    or os.getenv("INTERDIMUX_SHOW_TITLE") ~= "off" then
                  local activity = rex.call("com.superlogical.terminal.program_status", {
                    session_id = session.session_id, block_id = block.block_id, args = {},
                  })
                  if activity then
                    process.program_status = activity
                  else
                    incomplete_metadata[block.block_id] = true
                  end
                end
                metadata[block.block_id] = process
              end
            end
          end
        end
      end
    end
  else
    -- Sessions can disappear between the list and their view request.
    errors[session.session_id] = tostring(view_err)
  end
end

-- ID-keyed maps avoid Lua's ambiguous empty-array JSON representation.
return { version = 1, sessions = listed.sessions, views = views, errors = errors,
  metadata = metadata, incomplete_metadata = incomplete_metadata,
  host_id = status and status.host_id, local_host_id = local_host_id,
  sessions_only = args.sessions_only or nil }
