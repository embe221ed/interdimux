local root = arg[1] or "."
local ids = { "session:one", "session:closed" }
local view = {
  session_id = ids[1], active_window_id = "window:1", windows = {{
    window_id = "window:1", focused_block_id = "block:shell",
    layers = {{ blocks = {
      { block_id = "block:shell", creator_name = "com.superlogical.terminal", cwd = "/src" },
      { block_id = "block:imux", label = "interdimux", creator_name = "com.superlogical.terminal" },
    } }},
  }},
}

local function collect(host, failure)
  local calls = {}
  rex = {
    args = {host_id = "remote", session_ids = ids},
    session = { view = function(args)
      calls[#calls + 1] = "view"
      if args.session_id == ids[1] then return view end
    end },
    call = function(method, args)
      calls[#calls + 1] = method
      if method == "session.bootstrap" then
        assert(args.event_scope == "session" and args.attach_session_ids == ids)
        if failure then return nil, failure end
        return { server_status = {host_id = host}, attached_sessions = {
          {session = {session_id = ids[1]}, view = view},
        }}
      end
      if method == "server.status" then return {host_id = host} end
      if method == "session.attach_all" then return {} end
      assert(method == "com.superlogical.terminal.process" and args.block_id == "block:imux")
      return { child = {path = "/bin/imux"} }
    end,
  }
  local ok, result = pcall(dofile, root .. "/rust/src/rex_remote_layouts.lua")
  return ok, result, calls
end

for _, failure in ipairs({false, "code=method_not_found", 'unknown field "attach_session_ids"'}) do
  local ok, result, calls = collect("remote", failure)
  assert(ok and result.host_id == "remote" and result.layouts[ids[2]] == nil)
  local window = result.layouts[ids[1]][1]
  assert(window.active and #window.panes == 1)
  assert(window.panes[1].focused and window.panes[1].terminal and window.panes[1].cwd == "/src")
  assert(#calls == (failure and 6 or 2))
  ok, result, calls = collect("replacement", failure)
  assert(not ok and result:find("host changed", 1, true) and #calls == (failure and 2 or 1))
end
local ok, result, calls = collect("remote", "unreachable")
assert(not ok and result == "unreachable" and #calls == 1)
