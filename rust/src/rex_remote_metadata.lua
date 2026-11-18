-- A separate pass after the remote layout is already searchable. Only ship
-- the fields the picker needs for names and paths, including title ownership.
local args = rex.args or {}
local status, status_error = rex.call("server.status", {})
if not status then error(status_error, 0) end
if type(args.host_id) ~= "string" or args.host_id == "" or status.host_id ~= args.host_id then
  error("The Rex host changed while collecting terminal metadata.", 0)
end

local attached, attach_error = rex.call("session.attach_all", { event_scope = "session" })
if not attached then error(attach_error, 0) end

local function process_fields(process)
  if type(process) ~= "table" then return end
  return {
    pid = process.pid, name = process.name, argv0 = process.argv0,
    script = process.script, cwd = process.cwd,
  }
end

local show_title = os.getenv("INTERDIMUX_SHOW_TITLE") ~= "off"
local function collect(panes)
  local metadata = {}
  for _, pane in ipairs(panes) do
    local target = { session_id = pane.session_id, block_id = pane.block_id, args = {} }
    local process = rex.call("com.superlogical.terminal.process", target)
    if process then
      local foreground = process_fields(process.foreground)
      local details = { foreground = foreground, child = process_fields(process.child) }
      if show_title and foreground and foreground.pid and foreground.name then
        local title = rex.call("com.superlogical.terminal.title", target)
        if title then
          details.title = title.title
          if type(title.owner) == "table" then
            details.title_owner = { pid = title.owner.pid, name = title.owner.name }
          end
        end
      end
      metadata[pane.block_id] = details
    end
  end
  return { host_id = status.host_id, metadata = metadata }
end

local first = collect(args.panes)
if not (args.more and rex.json and rex.json.encode and rex.json.decode and io and io.lines and io.write and io.flush) then
  return first
end

-- This one host job already has a verified, attached control connection.
-- Publish each small batch before Rust supplies the next one through stdin.
local function emit(reply)
  io.write(rex.json.encode(reply), "\n")
  io.flush()
end
first.imux_metadata_stream = true
emit(first)
for line in io.lines() do
  emit(collect(rex.json.decode(line)))
end
