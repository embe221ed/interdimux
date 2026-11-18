-- Optional macOS binding: mocked Rex only, with no process or UI launches.
local root = arg[1] or "."
local started
local terminal_actions = { interdimux_schedule = {}, interdimux_jobs = {}, interdimux_health = {} }
local actions, bindings = {}, { ["ctrl+b>w"] = "interdimux" }
for name, definition in pairs(terminal_actions) do actions[name] = definition end
local checked_files, list_calls, block_calls, local_list_calls = {}, 0, 0, 0
local missing_file, expected_session = nil, "session"
local real_open = io.open
io.open = function(path, mode)
  assert(mode == "rb")
  checked_files[#checked_files + 1] = path
  if path == missing_file then return nil, "missing" end
  return { close = function() end }
end
local clients = {
  { client_id = "app", info = { platform = "macos" }, principal = { kind = "peer", transport = "unix" } },
  { client_id = "remote", info = { platform = "macos" }, principal = { kind = "peer", transport = "unix", path = { "login-server" } } },
  { client_id = "ios", info = { platform = "ios" }, principal = { kind = "peer", transport = "unix" } },
  { client_id = "lost", info = { platform = "macos" }, principal = { kind = "peer", transport = "unix" }, connection_state = "lost" },
}
local blocks = {
  { window_id = "wrong-window", block_id = "other-pane", placement = "placed" },
  { window_id = "exact-window", block_id = "origin-pane", placement = "placed" },
  { block_id = "detached-pane", placement = "detached" },
  { window_id = "wrong-window", block_id = "unknown-placement", placement = "unknown" },
}
local start_error, local_list_error
rex = {
  action = function(definition) actions[definition.name] = definition end,
  bind = function(key, name) bindings[key] = name end,
  call = function(method, args)
    if method == "session.list_blocks" then
      assert(args.session_id == expected_session)
      block_calls = block_calls + 1
      return { blocks = blocks }
    end
    assert(method == "client.list" and #args.kinds == 1 and args.kinds[1] == "app")
    list_calls = list_calls + 1
    return { clients = clients }
  end,
  json = { decode = function(data)
    assert(data == "local-client-list")
    return { clients = clients }
  end },
  exec = setmetatable({
    start = function(command, options)
      if start_error then return nil, start_error end
      started = { command = command, options = options }
      return {}
    end,
  }, { __call = function(_, command, options)
    local_list_calls = local_list_calls + 1
    assert(table.concat(command, "|") == '/path/to/rex|--autostart=false|--color=never|--timeout=1s|api|call|client.list|{"kinds":["app"]}')
    assert(options.env.REX_SERVER == false and options.env.REX_SESSION == false and options.timeout == 2)
    if local_list_error then return { ok = false, stderr = local_list_error } end
    return { ok = true, stdout = "local-client-list" }
  end }),
}
dofile(root .. "/integrations/rex_macos.lua").setup { root = root, rex_binary = "/path/to/rex" }
assert(bindings["ctrl+b>f"] == "interdimux_macos" and bindings["ctrl+b>g"] == "interdimux_macos_dashboard")
assert(bindings["ctrl+b>w"] == "interdimux" and bindings["ctrl+b>u"] == nil,
  "native defaults must leave terminal/optional alias bindings untouched")
for name, definition in pairs(terminal_actions) do
  assert(actions[name] == definition, "terminal Schedule/Jobs/Health actions must remain registered")
end

local function check_action(name, host)
  local action = assert(actions[name])
  checked_files, list_calls, block_calls, local_list_calls = {}, 0, 0, 0
  expected_session = "session"
  blocks[2].window_id, blocks[2].block_id = "exact-window", "origin-pane"
  local origin = { client_id = "app", session_id = "session", block_id = "origin-pane" }
  action.run(origin)
  local app = root .. "/macos/build/Interdimux Picker.app"
  assert(table.concat(started.command, "|") == "/usr/bin/open|-g|-a|" .. app
    .. "|interdimux-picker://" .. host .. "?client_id=app&session_id=session&window_id=exact-window&block_id=origin-pane")
  assert(#checked_files == 3 and list_calls == 1 and block_calls == 1 and local_list_calls == 0,
    "hotkey must only inspect the bundle and use existing Rex calls, without a blocking child process")
  assert(started.options.detach and started.options.stdout == false and started.options.stderr == false)
  assert(started.options.env.REX_CLIENT == false and started.options.env.REX_SERVER == false)
  for _, client_id in ipairs({ "remote", "ios", "lost", "cli", "missing" }) do
    checked_files, started = {}, nil
    local ok, err = pcall(action.run, { client_id = client_id, session_id = "session", block_id = "origin-pane" })
    assert(not ok and tostring(err):find("local macOS Rex app", 1, true))
    assert(#checked_files == 0 and not started, "unsupported clients must fail before reading or spawning anything")
  end
  local cli = { client_id = "cli", session_id = "session", block_id = "origin-pane" }
  action.run(cli, { client_id = "app" })
  assert(started.command[5]:find("client_id=app&", 1, true) and cli.client_id == "cli",
    "explicit app target must not mutate caller context")
  for _, file in ipairs({ "MacOS/InterdimuxPicker", "Helpers/imux", "Resources/build-stamp" }) do
    missing_file, started = app .. "/Contents/" .. file, nil
    local ok, err = pcall(action.run, origin)
    assert(not ok and tostring(err):find("Build the native picker first", 1, true) and not started,
      "missing bundle parts must produce a visible error before launch")
  end
  missing_file, start_error = nil, "cannot start launcher"
  local ok, err = pcall(action.run, origin)
  assert(not ok and tostring(err):find(start_error, 1, true))
  start_error = nil
  for _, block_id in ipairs({ "closed-pane", "detached-pane", "unknown-placement" }) do
    started = nil
    ok, err = pcall(action.run, { client_id = "app", session_id = "session", block_id = block_id })
    assert(not ok and tostring(err):find("originating Rex pane", 1, true) and not started)
  end
  assert(not pcall(action.run, { client_id = "app" }), "missing origin must fail early")

  -- URL fields are bytes, not a shell command. Quotes, Unicode, metacharacters,
  -- and delimiters must round-trip without creating extra query parameters.
  local hostile = "session:a & b/é?$(touch nope)#fragment'\"+%東京"
  expected_session = hostile
  local hostile_block = "block:[]'\"&é"
  blocks[2].window_id, blocks[2].block_id = "window:+/東京", hostile_block
  action.run { client_id = "app", session_id = hostile, block_id = hostile_block }
  local values, count = {}, 0
  for key, value in started.command[5]:gmatch("[?&]([^=]+)=([^&]+)") do
    count = count + 1
    values[key] = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  end
  assert(count == 4 and values.client_id == "app" and values.session_id == hostile
    and values.window_id == blocks[2].window_id and values.block_id == hostile_block)
  assert(started.command[5]:find("interdimux-picker://" .. host .. "?", 1, true) == 1)
  assert(#started.command == 5 and started.command[4] == app, "launch arguments must remain separate")

  checked_files, list_calls, block_calls, local_list_calls, started = {}, 0, 0, 0, nil
  local remote = { client_id = "app", server = "dev & build", session_id = "session:remote", block_id = "block:/é" }
  action.run(remote)
  assert(started.command[5] == "interdimux-picker://" .. host
    .. "?client_id=app&origin_server=dev%20%26%20build&origin_session_id=session%3Aremote&origin_block_id=block%3A%2F%C3%A9")
  assert(#checked_files == 3 and list_calls == 0 and block_calls == 0 and local_list_calls == 1,
    "a remote-origin launch must not issue any host-routed API calls")
  remote.window_id = "window:remote tab"
  action.run(remote)
  assert(started.command[5]:match("&origin_window_id=window%%3Aremote%%20tab$"),
    "a known remote tab must round-trip without an additional API lookup")
  remote.block_id, remote.window_id = nil, nil
  action.run(remote)
  assert(started.command[5] == "interdimux-picker://" .. host
    .. "?client_id=app&origin_server=dev%20%26%20build&origin_session_id=session%3Aremote"
    and list_calls == 0 and block_calls == 0,
    "a remote palette with only a session must launch without waiting for the host")
  remote.client_id, started = "remote", nil
  ok, err = pcall(action.run, remote)
  assert(not ok and tostring(err):find("local macOS Rex app", 1, true) and not started)
  remote.client_id, local_list_error = "app", "local lookup failed"
  ok, err = pcall(action.run, remote)
  assert(not ok and tostring(err):find(local_list_error, 1, true) and not started)
  local_list_error = nil
end
check_action("interdimux_macos", "open")
check_action("interdimux_macos_dashboard", "dashboard")
local integration = dofile(root .. "/integrations/rex_macos.lua")
local config = { root = root, rex_binary = "/path/to/rex" }
integration.setup(config)
local remote_key = { origin = "key", client_id = "app", server = "build", session_id = "session:remote" }
local_list_calls = 0
actions.interdimux_macos.run(remote_key)
assert(local_list_calls == 1, "first remote hotkey must verify its originating app")
remote_key.origin = "palette"
actions.interdimux_macos_dashboard.run(remote_key, {})
assert(local_list_calls == 1 and started.command[5]:find("picker://dashboard?", 1, true),
  "a repeated action from the same connected app must not start a validation CLI")
local_list_error = "unavailable"
for _, call in ipairs({
    { remote_key, { client_id = "app" } },
    { { origin = "cli", client_id = "app", server = "build", session_id = "s" } },
    { { origin = "key", client_id = "reconnected", server = "build", session_id = "s" } },
}) do
  started = nil
  local ok, err = pcall(actions.interdimux_macos.run, call[1], call[2])
  assert(not ok and tostring(err):find("unavailable", 1, true) and not started,
    "an override, CLI request or new connection must obtain its own verification")
end
local_list_error = nil
clients[1].connection_state = "lost"
assert(not pcall(actions.interdimux_macos.run, remote_key, { client_id = "app" }))
assert(not pcall(actions.interdimux_macos.run, remote_key),
  "fresh evidence of disconnection must clear the previously verified caller")
clients[1].connection_state = nil
integration.setup(config)
local_list_calls = 0
expected_session = "session"
blocks[2].window_id, blocks[2].block_id = "exact-window", "origin-pane"
actions.interdimux_macos.run { origin = "key", client_id = "app", session_id = "session", block_id = "origin-pane" }
actions.interdimux_macos.run(remote_key)
assert(local_list_calls == 0, "a key verified in a local tab must be reusable from a remote tab")
integration.setup(config)
actions.interdimux_macos.run(remote_key)
assert(local_list_calls == 1, "reloading the configuration must clear the verified caller")
dofile(root .. "/integrations/rex_macos.lua").setup {
  root = root, key = "ctrl+b>u", dashboard_key = "ctrl+b>d",
}
assert(bindings["ctrl+b>u"] == "interdimux_macos" and bindings["ctrl+b>d"] == "interdimux_macos_dashboard")
assert(bindings["ctrl+b>w"] == "interdimux")
io.open = real_open
print("passed: native picker/dashboard bindings, direct launch, encoded local and remote origins, local app guard, bounded checks, visible launch errors")
