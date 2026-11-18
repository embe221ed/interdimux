local root = arg[1] or "."
local target = {
  host_id = "host:remote", session_id = "session:remote",
  window_id = "window:target", block_id = "block:target",
  reveal = {"imux", "macos-serve", "--show-session", "123", "birth", "remote", "session:remote"},
}
local view = {
  session_id = target.session_id,
  windows = {
    {window_id = "window:target", layers = {{blocks = {{block_id = "block:target"}}}}},
    {window_id = "window:other", layers = {{blocks = {{block_id = "block:other"}}}}},
  },
}

local function exercise(opts, expected_calls, expected_error)
  local calls = {}
  local status = {host_id = opts.host_id or target.host_id}
  local selected = opts.view or view
  rex = {
    args = target,
    call = function(method, args)
      calls[#calls + 1] = method:gsub("^session%.", "")
      if method == "session.bootstrap" then
        assert(args.event_scope == "session" and #args.attach_session_ids == 1)
        assert(args.attach_session_ids[1] == target.session_id)
        if opts.bootstrap_error then return nil, opts.bootstrap_error end
        return {server_status = status, attached_sessions = {{view = selected}}}
      end
      if method == "server.status" then return status end
      if method == "target.resolve" then
        assert(args.scope.session == target.session_id and args.scope.window == target.window_id)
        assert(args.queries[1] == target.block_id and args.kinds[1] == "block")
        if opts.resolve_error then return nil, opts.resolve_error end
        return {results = {{status = opts.match_status or "resolved", target = {
          session_id = target.session_id, window_id = opts.window_after_show or target.window_id,
          block_id = opts.block_after_show or target.block_id,
        }}}}
      end
      assert(args.session_id == target.session_id)
      if method == "session.attach" then return {view = selected} end
      if method == "session.focus_block" then assert(args.block_id == target.block_id)
      elseif method == "session.focus_window" then assert(args.window_id == target.window_id)
      else error("Unexpected API call: " .. method) end
      if opts.focus_error then return nil, opts.focus_error end
      return {}
    end,
    exec = function(argv)
      assert(argv == target.reveal)
      calls[#calls + 1] = "show"
      return {ok = not opts.show_error, stderr = opts.show_error}
    end,
  }
  local ok, result = pcall(dofile, root .. "/rust/src/rex_focus_remote.lua")
  assert(table.concat(calls, ",") == expected_calls, table.concat(calls, ","))
  if expected_error then
    assert(not ok and tostring(result):find(expected_error, 1, true), tostring(result))
  else
    assert(ok and result.focused == true, tostring(result))
  end
end

exercise({}, "bootstrap,show,target.resolve,focus_block")
exercise({bootstrap_error = "code=method_not_found"}, "bootstrap,server.status,attach,show,target.resolve,focus_block")
exercise({bootstrap_error = 'unknown field "attach_session_ids"'},
         "bootstrap,server.status,attach,show,target.resolve,focus_block")
exercise({bootstrap_error = "server unavailable"}, "bootstrap", "server unavailable")
exercise({host_id = "host:other"}, "bootstrap", "host changed")
exercise({host_id = "host:other", bootstrap_error = "code=method_not_found"},
         "bootstrap,server.status", "host changed")
exercise({view = {session_id = "session:other", windows = view.windows}}, "bootstrap", "session no longer exists")
exercise({view = {session_id = target.session_id}}, "bootstrap", "tab no longer exists")

target.block_id = "block:other"
exercise({}, "bootstrap", "pane moved or closed")
target.block_id = "block:target"
exercise({show_error = "Rex app closed"}, "bootstrap,show", "Rex app closed")
exercise({match_status = "not_found"}, "bootstrap,show,target.resolve", "The session opened, but")
exercise({window_after_show = "window:other"}, "bootstrap,show,target.resolve", "pane moved or closed")
exercise({block_after_show = "block:other"}, "bootstrap,show,target.resolve", "pane moved or closed")
exercise({resolve_error = "code=method_not_found"}, "bootstrap,show,target.resolve,attach,focus_block")
exercise({resolve_error = "permission denied"}, "bootstrap,show,target.resolve", "permission denied")
exercise({focus_error = "pane closed"}, "bootstrap,show,target.resolve,focus_block", "The session opened, but")

target.block_id = nil
exercise({}, "bootstrap,show,focus_window")
exercise({focus_error = "tab closed"}, "bootstrap,show,focus_window", "The session opened, but")
