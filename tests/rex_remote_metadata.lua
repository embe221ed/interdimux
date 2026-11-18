local root = arg[1] or "."
local expected_host = "host:remote"
local targets = {
  { session_id = "session:remote", block_id = "block:closed" },
  { session_id = "session:remote", block_id = "block:editor" },
  { session_id = "session:remote", block_id = "block:shell" },
}

local function collect(host_id, show_title, fail_title, stream)
  local calls = {}
  local replies = {}
  local getenv = os.getenv
  local original_io = io
  os.getenv = function(key)
    if key == "INTERDIMUX_SHOW_TITLE" and not show_title then return "off" end
  end
  rex = {
    args = { host_id = expected_host, panes = targets, more = true },
    call = function(method, args)
      calls[#calls + 1] = method
      if method == "server.status" then return { host_id = host_id } end
      if method == "session.attach_all" then
        assert(args.event_scope == "session")
        return {}
      end
      assert(args.session_id == "session:remote")
      if method == "com.superlogical.terminal.process" then
        if args.block_id == "block:closed" then return nil, "pane closed" end
        if args.block_id == "block:shell" then return { child = { name = "zsh", cwd = "/src" } } end
        assert(args.block_id == "block:editor")
        return { foreground = { pid = 42, name = "nvim", cwd = "/editor", argv = { "irrelevant" } } }
      end
      assert(method == "com.superlogical.terminal.title" and args.block_id == "block:editor")
      if fail_title then return nil, "terminal title unavailable" end
      return { title = "Editor title", owner = { pid = 42, name = "nvim" } }
    end,
  }
  if stream then
    rex.json = {
      encode = function(reply) replies[#replies + 1] = reply; return "reply" end,
      decode = function(line)
        assert(line == "next")
        return {targets[3]}
      end,
    }
    local lines = {"next", "next"}
    io = {
      write = function(line, newline) assert(line == "reply" and newline == "\n") end,
      flush = function() end,
      lines = function() return function() return table.remove(lines) end end,
    }
  end
  local ok, reply = pcall(dofile, root .. "/rust/src/rex_remote_metadata.lua")
  io = original_io
  os.getenv = getenv
  return ok, reply, calls, replies
end

local ok, reply, calls = collect(expected_host, true)
assert(ok and reply.host_id == expected_host and #calls == 6)
assert(reply.metadata["block:closed"] == nil)
assert(reply.metadata["block:shell"].child.cwd == "/src")
local editor = reply.metadata["block:editor"]
assert(editor.foreground.name == "nvim" and editor.foreground.argv == nil)
assert(editor.title == "Editor title" and editor.title_owner.pid == 42 and editor.title_owner.name == "nvim")

ok, reply, calls = collect(expected_host, true, true)
assert(ok and #calls == 6 and reply.metadata["block:editor"].foreground.name == "nvim")
assert(reply.metadata["block:editor"].title == nil)

ok, reply, calls = collect(expected_host, false)
assert(ok and #calls == 5 and reply.metadata["block:editor"].title == nil)

ok, reply, calls = collect("host:replacement", true)
assert(not ok and reply:find("host changed", 1, true) and #calls == 1)

local replies
ok, reply, calls, replies = collect(expected_host, true, false, true)
assert(ok and reply == nil and #replies == 3 and #calls == 8)
assert(calls[1] == "server.status" and calls[2] == "session.attach_all")
assert(replies[1].imux_metadata_stream and replies[1].metadata["block:editor"].title == "Editor title")
for i = 2, 3 do
  assert(calls[5 + i] == "com.superlogical.terminal.process")
  assert(replies[i].host_id == expected_host and replies[i].metadata["block:shell"].child.name == "zsh")
  assert(not replies[i].metadata["block:editor"])
end
