-- Optional macOS binding: mocked Rex only, with no process or UI launches.
local root = arg[1] or "."
local started
local terminal_actions = { interdimux_schedule = {}, interdimux_jobs = {}, interdimux_health = {} }
local actions, bindings = {}, { ["ctrl+b>w"] = "interdimux" }
for name, definition in pairs(terminal_actions) do actions[name] = definition end
local checked_files, list_calls, view_calls = {}, 0, 0
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
local view = { windows = {
  { window_id = "wrong-window", layers = { { blocks = { { block_id = "other-pane" } } } } },
  { window_id = "exact-window", layers = { { blocks = { { block_id = "origin-pane" } } } } },
} }
local start_error
rex = {
  action = function(definition) actions[definition.name] = definition end,
  bind = function(key, name) bindings[key] = name end,
  call = function(method, args)
    assert(method == "client.list" and #args.kinds == 1 and args.kinds[1] == "app")
    list_calls = list_calls + 1
    return { clients = clients }
  end,
  session = { view = function(args)
    assert(args.session_id == expected_session)
    view_calls = view_calls + 1
    return view
  end },
  exec = {
    start = function(command, options)
      if start_error then return nil, start_error end
      started = { command = command, options = options }
      return {}
    end,
  },
}
dofile(root .. "/integrations/rex_macos.lua").setup { root = root }
assert(bindings["ctrl+b>f"] == "interdimux_macos" and bindings["ctrl+b>g"] == "interdimux_macos_dashboard")
assert(bindings["ctrl+b>w"] == "interdimux" and bindings["ctrl+b>u"] == nil,
  "native defaults must leave terminal/optional alias bindings untouched")
for name, definition in pairs(terminal_actions) do
  assert(actions[name] == definition, "terminal Schedule/Jobs/Health actions must remain registered")
end

local function check_action(name, host)
  local action = assert(actions[name])
  checked_files, list_calls, view_calls = {}, 0, 0
  expected_session = "session"
  view.windows[2].window_id = "exact-window"
  view.windows[2].layers[1].blocks[1].block_id = "origin-pane"
  local origin = { client_id = "app", session_id = "session", block_id = "origin-pane" }
  action.run(origin)
  local app = root .. "/macos/build/Interdimux Picker.app"
  assert(table.concat(started.command, "|") == "/usr/bin/open|-g|-a|" .. app
    .. "|interdimux-picker://" .. host .. "?client_id=app&session_id=session&window_id=exact-window&block_id=origin-pane")
  assert(#checked_files == 3 and list_calls == 1 and view_calls == 1,
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
  ok = pcall(action.run, { client_id = "app", session_id = "session", block_id = "closed-pane" })
  assert(not ok, "vanished origin must not fall back to the active window")
  assert(not pcall(action.run, { client_id = "app" }), "missing origin must fail early")

  -- URL fields are bytes, not a shell command. Quotes, Unicode, metacharacters,
  -- and delimiters must round-trip without creating extra query parameters.
  local hostile = "session:a & b/é?$(touch nope)#fragment'\"+%東京"
  expected_session = hostile
  local hostile_block = "block:[]'\"&é"
  view.windows[2].window_id = "window:+/東京"
  view.windows[2].layers[1].blocks[1].block_id = hostile_block
  action.run { client_id = "app", session_id = hostile, block_id = hostile_block }
  local values, count = {}, 0
  for key, value in started.command[5]:gmatch("[?&]([^=]+)=([^&]+)") do
    count = count + 1
    values[key] = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  end
  assert(count == 4 and values.client_id == "app" and values.session_id == hostile
    and values.window_id == view.windows[2].window_id and values.block_id == hostile_block)
  assert(started.command[5]:find("interdimux-picker://" .. host .. "?", 1, true) == 1)
  assert(#started.command == 5 and started.command[4] == app, "launch arguments must remain separate")
end
check_action("interdimux_macos", "open")
check_action("interdimux_macos_dashboard", "dashboard")
dofile(root .. "/integrations/rex_macos.lua").setup {
  root = root, key = "ctrl+b>u", dashboard_key = "ctrl+b>d",
}
assert(bindings["ctrl+b>u"] == "interdimux_macos" and bindings["ctrl+b>d"] == "interdimux_macos_dashboard")
assert(bindings["ctrl+b>w"] == "interdimux")
io.open = real_open
print("passed: native picker/dashboard bindings, retained terminal actions, direct launch, exact encoded origin, local app guard, explicit CLI target, bounded file checks, visible build/start errors")
