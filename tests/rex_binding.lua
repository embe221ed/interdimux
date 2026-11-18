-- Integration action/binding regressions with no Rex server, process or UI.
-- lua tests/rex_binding.lua [checkout-root]
local root = arg[1] or "."
local actions, bindings, starts, focuses, handles, processes = {}, {}, {}, {}, {}, {}
local definitions = {}
local sessions = { { session_id = "c" }, { session_id = "b" }, { session_id = "a" } }
local history = { last = 300, sessions = { a = 300, b = 200, c = 100, closed = 900 } }
local queued, performed, remembered, api_calls = {}, {}, {}, {}
local remote_layers, attach_error, layer_error = {}
local list_error, perform_error
local session_views = 0
local real_dofile = dofile
dofile = function(path)
  if path == root .. "/rust/src/rex_history.lua" then
    return { for_server_config = function()
      return {
        read = function() return history end,
        remember = function(target, origin, client)
          remembered[#remembered + 1] = { target, origin, client }
          history.last = history.last + 1; history.sessions[origin] = history.last
          history.last = history.last + 1; history.sessions[target] = history.last
        end,
      }
    end }
  end
  return real_dofile(path)
end
local clients = { { client_id = "app" }, { client_id = "other-app" },
  { client_id = "disconnected-app", connection_state = "lost" } }
local function window(id, block)
  return { window_id = id, layers = { { kind = "tiled", blocks = { { block_id = block, label = "shell" } } } } }
end
local views = {
  a = { windows = { window("a1", "pane:a1"), window("a2", "pane:a2"), window("a3", "pane:a3") } },
  b = { windows = { window("b1", "pane:b1") } },
}
rex = {
  action = function(action) actions[action.name] = action.run; definitions[action.name] = action end,
  bind = function(key, action) bindings[key] = action end,
  json = { encode = function(value) starts[#starts + 1] = value; return "request" end },
  client = { queue = function(action, args) queued[#queued + 1] = { action = action, args = args } end },
  layout = { block = function(block) return { block = block } end },
  session = {
    new_layer = function(payload)
      if layer_error then return nil, layer_error end
      remote_layers[#remote_layers + 1] = payload
      return { layer_id = "remote-layer" }
    end,
    view = function(payload) session_views = session_views + 1; return views[payload.session_id] end,
    set_layer_state = function(payload) focuses[#focuses + 1] = payload; return {} end,
  },
  call = function(method, payload)
    api_calls[#api_calls + 1] = method
    if method == "session.attach" then
      if attach_error then return nil, attach_error end
      assert(views[payload.session_id], "unknown remote session")
      return { client_id = "app-on-remote", view = views[payload.session_id] }
    end
    if method == "client.list" then
      assert(#payload.kinds == 1 and payload.kinds[1] == "app")
      return { clients = clients }
    end
    if method == "session.list" then
      if list_error then return nil, list_error end
      return { sessions = sessions }
    end
    if method == "client.perform" then
      if perform_error then return nil, perform_error end
      performed[#performed + 1] = payload; return {}
    end
    assert(method == "com.superlogical.terminal.process", "binding setup must not mutate app state")
    return processes[payload.block_id] or { child = { path = "/bin/zsh", name = "zsh" } }
  end,
  exec = { start = function(argv, options)
    assert(argv[1] == "/bin/sh" and options.detach == true)
    assert(options.stdout == false and options.stderr == false, "no callbacks may outlive the config action")
    local handle = { active = true }
    function handle:running() return self.active end
    handles[#handles + 1] = handle
    return handle
  end },
}
dofile(root .. "/integrations/rex.lua").setup {
  root = root, binary = "/bin/sh", rex_binary = "/bin/sh", jump_keys = 2,
  agent_next_key = "ctrl+b>!",
  last_session_key = "ctrl+b>shift+l",
}
assert(bindings["ctrl+b>f"] == "interdimux" and bindings["ctrl+b>g"] == "interdimux_dashboard")
assert(bindings["ctrl+b>1"] == "interdimux_jump_1" and bindings["ctrl+b>2"] == "interdimux_jump_2")
assert(bindings["ctrl+b>!"] == "interdimux_agent_next")
assert(bindings["ctrl+b>shift+l"] == "interdimux_last_session")
local function invoke(session, win, action, client)
  actions[action or "interdimux"] { client_id = client or "app", session_id = session, block_id = "pane:" .. win }
end
invoke("a", "a1")
invoke("a", "a1")
assert(#starts == 1, "one pending origin may not launch duplicate coordinators")
invoke("b", "b1")
assert(#starts == 2 and starts[2].session_id == "b", "a running picker in another session cannot lock out the hotkey")
invoke("a", "a2")
assert(#starts == 3 and starts[3].window_id == "a2", "a running picker in another window cannot lock out the hotkey")
local function float(win, id, executable)
  local block = { block_id = id, label = "interdimux", creator_name = "com.superlogical.terminal", owner = "app" }
  win.layers[#win.layers + 1] = { kind = "floating", layer_id = "layer:" .. id, blocks = { block } }
  processes[id] = { child = { path = executable, name = executable:match("([^/]+)$") } }
end
float(views.a.windows[1], "picker:a1", "/opt/tools/interdimux/rust/target/release/imux")
invoke("a", "a2")
assert(#focuses == 0 and #starts == 3, "another window's floating picker must not steal focus")
float(views.a.windows[2], "picker:a2", "/opt/tools/interdimux/rust/target/release/imux")
invoke("a", "a2")
assert(#focuses == 1 and focuses[1].layer_id == "layer:picker:a2" and #starts == 3,
  "an existing picker is focused only in the requested origin window")
invoke("a", "a2", nil, "other-app")
assert(#starts == 4, "another app's coordinator must not consume this client's hotkey")
handles[3].active = false
views.a.windows[2].layers[2] = nil
invoke("a", "a2", "interdimux_send")
assert(#starts == 5 and starts[5].mode == "send", "an exited coordinator can restart in the requested mode")
float(views.a.windows[3], "user:interdimux", "/bin/zsh")
invoke("a", "a3")
assert(#starts == 6 and #focuses == 1, "a legitimate float named interdimux is not an existing picker")
print("passed: action keys, per-client/session/window pending guards, scoped picker focus, mode restart, legitimate labels")

local cli = { client_id = "short-lived-cli", session_id = "a", block_id = "pane:a3" }
local before_cli = #starts
local launched, launch_error = pcall(actions.interdimux, cli)
assert(not launched and tostring(launch_error):find("client_id=<app ID>", 1, true))
assert(#starts == before_cli, "a CLI caller without an app target must fail before creating a coordinator")
actions.interdimux(cli, { client_id = "other-app" })
assert(#starts == before_cli + 1 and starts[#starts].client_id == "other-app")
assert(cli.client_id == "short-lived-cli", "target resolution must not mutate the action's original context")
for _, unavailable in ipairs({ "missing-app", "disconnected-app" }) do
  assert(not pcall(actions.interdimux, cli, { client_id = unavailable }))
  assert(#starts == before_cli + 1, "missing or disconnected targets must not leave a ghost float")
end
local commands, environments = {}, {}
setmetatable(rex.exec, { __call = function(_, command, options)
  commands[#commands + 1] = command
  environments[#environments + 1] = options.env
  return { ok = true }
end })
assert(not pcall(actions.interdimux_agent_next, cli))
assert(not pcall(actions.interdimux_jump_1, cli))
assert(not pcall(actions.interdimux_last_session, cli))
assert(#commands == 0, "direct actions also require a persistent app client")
actions.interdimux_agent_next(cli, { client_id = "app" })
actions.interdimux_jump_1(cli, { client_id = "other-app" })
assert(commands[1][2] == "agent-next" and commands[1][6] == "app")
assert(commands[2][2] == "jump" and commands[2][6] == "other-app")
assert(environments[2].INTERDIMUX_ORDER == nil, "numbered jumps retain the configured order")
print("passed: native and explicit CLI app identities, early rejection, and direct-action targets")

local before_views, before_calls = session_views, #api_calls
invoke("a", "a3", "interdimux_last_session")
assert(queued[1].action == "session.select" and queued[1].args.session_id == "b",
  "MRU excludes the current and closed sessions, regardless of list order")
assert(#api_calls == before_calls + 2 and api_calls[#api_calls] == "session.list",
  "a keyboard toggle needs only client validation and the session list")
invoke("b", "b1", "interdimux_last_session")
assert(queued[2].args.session_id == "a", "repeated shortcuts toggle back")
actions.interdimux_last_session(cli, { client_id = "other-app" })
assert(#queued == 2 and #performed == 1 and performed[1].client_id == "other-app"
  and performed[1].args.session_id == "b", "CLI calls must target the requested app")
assert(remembered[3][1] == "b" and remembered[3][2] == "a" and remembered[3][3] == "other-app")
assert(#commands == 2 and session_views == before_views, "last-session must not spawn processes or inspect panes")
local before_remembered = #remembered
perform_error = "selection failed"
assert(not pcall(actions.interdimux_last_session, cli, { client_id = "other-app" }))
assert(#remembered == before_remembered, "failed CLI selection must not change history")
perform_error = nil
list_error = "list failed"
assert(not pcall(actions.interdimux_last_session, { client_id = "app", session_id = "a" }))
list_error = nil
sessions = { { session_id = "b" } }
assert(not pcall(actions.interdimux_last_session, { client_id = "app", session_id = "a" }))
invoke("b", "b1", "interdimux_last_session")
assert(#queued == 2 and #remembered == before_remembered, "a lone session is a no-op; stale origins are rejected")
sessions = { { session_id = "c" }, { session_id = "b" }, { session_id = "a" } }
history = { last = 0, sessions = {} }
invoke("a", "a3", "interdimux_last_session")
assert(queued[3].args.session_id == "c", "unrecorded history retains session-order fallback")
print("passed: native MRU toggle, closed-session filtering, shared history, errors, and zero-process keyboard path")

-- Each host assigns its own app ID. Standalone commands should receive the
-- exact remote client and origin even when other apps are attached.
local remote = { server = "remote-host", client_id = "home-app", session_id = "a", block_id = "pane:a1" }
clients = { { client_id = "app-on-remote" }, { client_id = "other-remote-app" } }
views.a.windows[1].zoomed_block_id = "pane:a1"
local launched_locally, queued_locally = #starts, #queued
for _, case in ipairs({
  { "interdimux", "pick", "--mode", "switch" },
  { "interdimux_agents", "pick", "--mode", "agents" },
  { "interdimux_dashboard", "pick", "--mode", "dashboard" },
  { "interdimux_agent_next", "agent-next" },
  { "interdimux_jump_2", "jump", "2" },
  { "interdimux_last_session", "jump", "1" },
}) do
  local before = #remote_layers
  actions[case[1]](remote)
  assert(#remote_layers == before + 1)
  local layer = remote_layers[#remote_layers]
  assert(layer.session_id == "a" and layer.window_id == "a1" and layer.focus)
  local command = layer.layout.block.options.command
  local first = case[1] == "interdimux_last_session" and 3 or 1
  if first == 3 then assert(command[1] == "env" and command[2] == "INTERDIMUX_ORDER=mru") end
  assert(command[first] == "sh" and command[first + 1] == "-c" and command[first+4] == root)
  local expected = { case[2], "--backend", "rex", "--client", "app-on-remote", "--session", "a",
    "--window", "a1", "--block", "pane:a1" }
  for i = 3, #case do expected[#expected + 1] = case[i] end
  expected[#expected + 1] = "--origin-zoom"
  expected[#expected + 1] = "pane:a1"
  assert(table.concat(command, "|", first + 5) == table.concat(expected, "|"), case[1])
end
views.a.active_window_id = "a1"
views.a.windows[1].focused_block_id = "pane:a1"
local palette = { server = remote.server, session_id = "a", client_id = "home-app" }
local before_palette_views = session_views
for _, name in ipairs({ "interdimux_last_session", "interdimux", "interdimux_agent_next" }) do
  actions[name](palette)
  local layer = remote_layers[#remote_layers]
  assert(layer.window_id == "a1" and not palette.block_id
    and table.concat(layer.layout.block.options.command, "|"):find("--block|pane:a1", 1, true),
    "remote palette actions must resolve the focused pane from the attached view")
end
assert(session_views == before_palette_views, "remote palette focus must reuse the existing attachment")
views.a.windows[1].focused_block_id = nil
assert(not pcall(actions.interdimux, palette), "a session without a focused pane must not guess an origin")
views.a.windows[1].focused_block_id = "pane:a1"
local remote_count = #remote_layers
sessions = { { session_id = "a" } }
actions.interdimux_last_session(remote)
assert(#remote_layers == remote_count, "a lone remote session must not launch a session jump")
attach_error = "remote disconnected"
local ok, err = pcall(actions.interdimux, remote)
assert(not ok and tostring(err):find(attach_error, 1, true))
attach_error = nil
layer_error = "remote launch failed"
ok, err = pcall(actions.interdimux_agent_next, remote)
assert(not ok and tostring(err):find(layer_error, 1, true))
layer_error = nil
assert(not pcall(actions.interdimux, { server = "remote", client_id = "home-app", session_id = "a", block_id = "closed" }))
assert(not pcall(actions.interdimux, remote, { client_id = "home-app" }))
assert(#remote_layers == remote_count and #starts == launched_locally and #queued == queued_locally
  and #commands == 2, "remote actions must not launch or perform on home")
clients = { { client_id = "app" } }
print("passed: remote client identity, standalone picker and agent commands, remote MRU, failures and exact origins")

actions, bindings, definitions = {}, {}, {}
local before_native = #starts
dofile(root .. "/integrations/rex.lua").setup {
  root = root, binary = "/bin/sh", rex_binary = "/bin/sh", dashboard_ui = "native",
}
assert(bindings["ctrl+b>g"] == "client.palette.toggle", "native dashboard goes straight to the app palette")
assert(bindings["ctrl+b>f"] == "interdimux", "native dashboard preserves the shared fuzzy switch picker")
assert(actions.interdimux_dashboard == nil, "the native palette must not offer a redundant terminal dashboard")
assert(bindings["ctrl+b>shift+l"] == nil, "last-session key is opt-in")
assert(#starts == before_native, "native palette setup must not start a hidden picker")
for name, definition in pairs(definitions) do
  assert(definition.category == "Interdimux" and definition.title:match("^Interdimux: "), name)
  assert(definition.keywords:find("imux", 1, true), name)
end
invoke("a", "a3", "interdimux_rename")
assert(#starts == before_native + 1 and starts[#starts].mode == "rename", "palette action retains its shared backend mode")
print("passed: native palette binding, searchable action grouping, no hidden dashboard, shared action dispatch")
