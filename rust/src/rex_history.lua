-- Standalone Rex commands share the hosted picker's MRU and project identity.
-- This runs in the CLI worker: never read its filesystem for a remote server.
local M = {}

local function local_peer()
  if not imux_collector_pid or not imux_collector_uid then return false end
  local identity = rex.call("server.whoami", {})
  local p = identity and identity.principal
  if not p or p.kind ~= "peer" or p.transport ~= "unix"
      or p.pid ~= imux_collector_pid or p.uid ~= imux_collector_uid
      or (p.path ~= nil and (type(p.path) ~= "table" or next(p.path) ~= nil)) then return false end
  local status = rex.call("server.status", {})
  return status and type(status.host_id) == "string" and status.host_id ~= ""
end

local function location()
  local state = os.getenv("XDG_STATE_HOME")
  if not state or state == "" then
    local home = os.getenv("HOME")
    if not home or home == "" then return end
    state = home .. "/.local/state"
  end
  return state .. "/interdimux", state .. "/interdimux/rex-mru.json"
end

local function read(path)
  local file = io.open(path, "rb")
  if not file then return end
  local text = file:read(2097153); file:close()
  if not text or #text > 2097152 then return end
  local ok, value = pcall(rex.json.decode, text)
  if not ok or type(value) ~= "table" or value.version ~= 1
      or type(value.sessions) ~= "table" then return end
  if type(value.paths) ~= "table" then value.paths = {} end
  return value
end

function M.enrich(snapshot)
  if type(snapshot.host_id) ~= "string" or snapshot.host_id == ""
      or snapshot.local_host_id ~= snapshot.host_id then return snapshot end
  local _, path = location()
  local history = path and read(path)
  if history then snapshot.mru = history.sessions; snapshot.session_paths = history.paths end
  return snapshot
end

function M.remember(session_id, cwd, origin_id)
  -- Persistence is best effort and must never turn successful navigation into
  -- an error. Read immediately before writing, preserving other commands' data.
  pcall(function()
    if type(session_id) ~= "string" or session_id == "" or not local_peer() then return end
    local parent, path = location()
    if not path then return end
    if not os.rename(parent, parent) then
      local made = rex.exec { "mkdir", "-p", parent }
      if not made or not made.ok then return end
    end
    local history = read(path) or { version = 1, last = 0, sessions = {}, paths = {} }
    if type(origin_id) == "string" and origin_id ~= "" and origin_id ~= session_id then
      history.last = math.max(os.time(), (tonumber(history.last) or 0) + 1)
      history.sessions[origin_id] = history.last
    end
    history.last = math.max(os.time(), (tonumber(history.last) or 0) + 1)
    history.sessions[session_id] = history.last
    if type(cwd) == "string" and cwd ~= "" then history.paths[session_id] = cwd end
    local temporary = path .. ".tmp-direct-" .. tostring(imux_collector_pid)
    local file = io.open(temporary, "wb")
    if not file then return end
    local written = pcall(function()
      assert(file:write(rex.json.encode(history))); assert(file:close())
    end)
    if not written then pcall(function() file:close() end); os.remove(temporary); return end
    local renamed = os.rename(temporary, path)
    if not renamed then os.remove(temporary) end
  end)
end

return M
