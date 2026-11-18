-- Keep the direct connection used for discovery until the preview panel closes.
if not (rex.json and rex.json.encode and rex.json.decode and io and io.read and io.lines and io.write and io.flush) then
  return "imux-preview-oneshot"
end

local function emit(value)
  io.write(rex.json.encode(value), "\n")
  io.flush()
end

local handshake = io.read("*l")
if not handshake then return end
local pid, uid = handshake:match("^(%d+) (%d+)$")
local clients = discover(tonumber(pid), tonumber(uid))
emit(clients)

local attached_session
for line in io.lines() do
  local ok, result = pcall(function()
    local request = rex.json.decode(line)
    request.operation = "preview"
    local session = request.target.session_id
    if attached_session and session ~= attached_session then
      -- Keep at most one session subscription while the panel is visible.
      local detached, err = rex.call("session.detach", { session_id = attached_session })
      if not detached then
        -- Rex versions differ on detaching a vanished session. A live prior
        -- session must release its subscription before we attach to another.
        local catalog = assert(rex.call("session.list", {}))
        assert(type(catalog.sessions) == "table", err)
        for _, entry in ipairs(catalog.sessions) do
          if entry.session_id == attached_session then error(err, 0) end
        end
      end
      attached_session = nil
    end
    local attached = assert(rex.call("session.attach", { session_id = session }))
    attached_session = session
    return operation(request, rex.args.context, attached.view)
  end)
  emit(ok and result or {error = tostring(result)})
end
