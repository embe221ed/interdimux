-- Integration action/binding regressions with no Rex server, process or UI.
-- lua tests/rex_binding.lua [checkout-root]
local root = arg[1] or "."
local actions, bindings, starts, focuses, handles, processes = {}, {}, {}, {}, {}, {}
local definitions = {}
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
  session = {
    view = function(payload) return views[payload.session_id] end,
    set_layer_state = function(payload) focuses[#focuses + 1] = payload; return {} end,
  },
  call = function(method, payload)
    if method == "client.list" then
      assert(#payload.kinds == 1 and payload.kinds[1] == "app")
      return { clients = clients }
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
}
assert(bindings["ctrl+b>f"] == "interdimux" and bindings["ctrl+b>g"] == "interdimux_dashboard")
assert(bindings["ctrl+b>1"] == "interdimux_jump_1" and bindings["ctrl+b>2"] == "interdimux_jump_2")
assert(bindings["ctrl+b>!"] == "interdimux_agent_next")
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
local commands = {}
setmetatable(rex.exec, { __call = function(_, command)
  commands[#commands + 1] = command
  return { ok = true }
end })
assert(not pcall(actions.interdimux_agent_next, cli))
assert(not pcall(actions.interdimux_jump_1, cli))
assert(#commands == 0, "direct actions also require a persistent app client")
actions.interdimux_agent_next(cli, { client_id = "app" })
actions.interdimux_jump_1(cli, { client_id = "other-app" })
assert(commands[1][2] == "agent-next" and commands[1][6] == "app")
assert(commands[2][2] == "jump" and commands[2][6] == "other-app")
print("passed: native and explicit CLI app identities, early rejection, and direct-action targets")

actions, bindings, definitions = {}, {}, {}
local before_native = #starts
dofile(root .. "/integrations/rex.lua").setup {
  root = root, binary = "/bin/sh", rex_binary = "/bin/sh", dashboard_ui = "native",
}
assert(bindings["ctrl+b>g"] == "client.palette.toggle", "native dashboard goes straight to the app palette")
assert(bindings["ctrl+b>f"] == "interdimux", "native dashboard preserves the shared fuzzy switch picker")
assert(actions.interdimux_dashboard == nil, "the native palette must not offer a redundant terminal dashboard")
assert(#starts == before_native, "native palette setup must not start a hidden picker")
for name, definition in pairs(definitions) do
  assert(definition.category == "Interdimux" and definition.title:match("^Interdimux: "), name)
  assert(definition.keywords:find("imux", 1, true), name)
end
invoke("a", "a3", "interdimux_rename")
assert(#starts == before_native + 1 and starts[#starts].mode == "rename", "palette action retains its shared backend mode")
print("passed: native palette binding, searchable action grouping, no hidden dashboard, shared action dispatch")
