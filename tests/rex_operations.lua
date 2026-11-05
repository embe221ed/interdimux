-- Native operation routing without a server. Run: lua tests/rex_operations.lua
local root = arg[1] or "."
local call_log = {}
local instance = "server-run-one"
local startup_polls = 0
local function terminal(id) return { block_id = id, label = id, creator_name = "com.superlogical.terminal" } end
local views = {
  s = { session_id = "s", active_window_id = "w1", windows = {
    { window_id = "w1", focused_block_id = "picker", layers = { { blocks = {
      terminal("b1"), terminal("b2"), terminal("picker"),
      { block_id = "onboarding", creator_name = "other" },
    } } } },
    { window_id = "w2", focused_block_id = "b3", layers = { { blocks = { terminal("b3") } } } },
  } },
  other = { session_id = "other", active_window_id = "ow", windows = {
    { window_id = "ow", focused_block_id = "ob", layers = { { blocks = { terminal("ob") } } } },
  } },
}
rex = { call = function(method, args)
  call_log[#call_log + 1] = { method = method, args = args }
  if method == "session.view" then return views[args.session_id] end
  if method == "server.status" then return { instance_id = instance, host_id = "host", api_revision = 10 } end
  if method == "com.superlogical.terminal.process" then return { foreground = { pid = 123, name = "zsh" } } end
  if method == "com.superlogical.terminal.modes" then
    startup_polls = startup_polls + 1
    return { modes = { { name = "bracketed_paste", set = startup_polls >= 2 } } }
  end
  if method == "session.create" then return { session_id = "fresh", initial_windows = { { window_id = "fresh-window", block_ids = { "fresh-pane" } } } } end
  if method == "com.superlogical.terminal.format" then return { content = "one\ntwo\nthree\n" } end
  return {}
end, sleep = function(seconds) assert(seconds == .05) end,
layout = { block = function(options) return { block = options } end } }
local operate = dofile(root .. "/integrations/rex_operations.lua")
local context = { hosted = true, session_id = "s", window_id = "w1",
  block_id = "b1", picker_block_id = "picker", client_id = "app" }
local function operation(name, target, args)
  call_log = {}
  return operate({ operation = name, target = target, args = args or {} }, context)
end
local function sent_ids()
  local ids = {}
  for _, call in ipairs(call_log) do
    if call.method == "com.superlogical.terminal.write" then ids[#ids + 1] = call.args.block_id end
  end
  table.sort(ids)
  return table.concat(ids, ",")
end

local literal = "literal '$HOME' $(never-evaluate)\n"
local result = operation("send", { session_id = "s", window_id = "w1" }, { text = literal, enter = true })
assert(result.sent == 2 and sent_ids() == "b1,b2")
for _, call in ipairs(call_log) do
  if call.method == "com.superlogical.terminal.write" then assert(call.args.args.data == literal) end
  if call.method == "block.event" then
    assert(call.args.block_id == "b1" or call.args.block_id == "b2")
    assert(call.args.event.type == "key" and call.args.event.payload.key == "enter")
  end
  assert(call.method ~= "client.perform", "send must not depend on the app's focused pane")
end
assert(operation("send", { session_id = "s" }, { text = "all" }).sent == 3)
assert(sent_ids() == "b1,b2,b3", "skip picker and nonterminal panes")
assert(operation("send", { session_id = "s", window_id = "w2", block_id = "b3" }, { text = "one", key = "ctrl+c" }).sent == 1)
assert(sent_ids() == "b3")
local key = call_log[#call_log]
assert(key.method == "block.event" and key.args.block_id == "b3")
assert(key.args.event.payload.key == "key_c" and key.args.event.payload.mods == "ctrl")
print("passed: exact pane/window/session send routing and modified keys")

local function key_payload(name)
  operation("send", { session_id = "s", block_id = "b1" }, { key = name })
  local event = call_log[#call_log]
  assert(event.method == "block.event" and event.args.block_id == "b1")
  return event.args.event.payload
end
local symbols = {
  { "~", "backquote", "`" }, { "!", "digit_1", "1" }, { "@", "digit_2", "2" },
  { "#", "digit_3", "3" }, { "$", "digit_4", "4" }, { "%", "digit_5", "5" },
  { "^", "digit_6", "6" }, { "&", "digit_7", "7" }, { "*", "digit_8", "8" },
  { "(", "digit_9", "9" }, { ")", "digit_0", "0" }, { "_", "minus", "-" },
  { "+", "equal", "=" }, { "{", "bracket_left", "[" }, { "}", "bracket_right", "]" },
  { "|", "backslash", "\\" }, { ":", "semicolon", ";" }, { '"', "quote", "'" },
  { "<", "comma", "," }, { ">", "period", "." }, { "?", "slash", "/" },
}
for _, symbol in ipairs(symbols) do
  local ctrl = key_payload("ctrl+" .. symbol[1])
  assert(ctrl.key == symbol[2] and ctrl.mods == "shift+ctrl" and ctrl.text == "", symbol[1])
  assert(ctrl.unshifted_codepoint == symbol[3]:byte(), symbol[1])
  local alt = key_payload("alt+" .. symbol[1])
  assert(alt.key == symbol[2] and alt.mods == "shift+alt" and alt.text == symbol[1], symbol[1])
  assert(alt.unshifted_codepoint == symbol[3]:byte(), symbol[1])
  local explicit = key_payload("shift+" .. symbol[3])
  assert(explicit.key == symbol[2] and explicit.mods == "shift" and explicit.text == symbol[1], symbol[1])
end
local plus = key_payload("+")
assert(plus.key == "equal" and plus.mods == "shift" and plus.text == "+")
local tab = key_payload("shift+tab")
assert(tab.key == "tab" and tab.mods == "shift" and tab.text == "" and tab.unshifted_codepoint == 0)
local letter = key_payload("ctrl+alt+x")
assert(letter.key == "key_x" and letter.mods == "ctrl+alt" and letter.text == "" and letter.unshifted_codepoint == 120)
print("passed: modified ASCII punctuation, literal plus, explicit shift, and named-key compatibility")

local closed, close_error = pcall(operation, "close", { session_id = "s", window_id = "w1", block_id = "b1" })
assert(not closed and tostring(close_error):find("finish the picker first", 1, true))
context.finished = true
operation("close", { session_id = "s", window_id = "w1", block_id = "b1" })
assert(call_log[#call_log].method == "block.close" and call_log[#call_log].args.block_id == "b1")
context.finished = nil
print("passed: origin close requires deferred completion")

local swapped, swap_error = pcall(operation, "swap", { session_id = "s", block_id = "b1" }, {
  other = { session_id = "other", window_id = "ow", block_id = "ob" },
})
assert(not swapped and tostring(swap_error):find("same session", 1, true))
for _, call in ipairs(call_log) do assert(call.method ~= "session.swap_blocks") end
assert(operation("preview", { session_id = "s", window_id = "w1", block_id = "b2" }, { lines = 2 }).text == "two\nthree")
print("passed: cross-session guard and bounded preview")

views.s.windows[#views.s.windows + 1] = { window_id = "w3", layers = {} }
operation("swap", { session_id = "s", window_id = "w1" }, { other = { session_id = "s", window_id = "w3" } })
local moved = {}
for _, call in ipairs(call_log) do
  assert(call.method ~= "session.swap_blocks", "window swap must not swap its active panes")
  assert(call.method ~= "session.focus_window" and call.method ~= "session.focus_block")
  if call.method == "session.move_window" then moved[#moved + 1] = call.args end
end
assert(#moved == 2)
assert(moved[1].window_id == "w3" and moved[1].before_window_id == "w1")
assert(moved[2].window_id == "w1" and moved[2].before_window_id == nil)
operation("swap", { session_id = "s", window_id = "w3" }, { other = { session_id = "s", window_id = "w1" } })
moved = {}
for _, call in ipairs(call_log) do if call.method == "session.move_window" then moved[#moved + 1] = call.args end end
assert(#moved == 2 and moved[1].window_id == "w3" and moved[1].before_window_id == "w1")
assert(moved[2].window_id == "w1")
local mixed, mixed_error = pcall(operation, "swap", { session_id = "s", window_id = "w1" }, {
  other = { session_id = "s", window_id = "w2", block_id = "b3" },
})
assert(not mixed and tostring(mixed_error):find("two windows or two panes", 1, true))
print("passed: exact window-order swap and mixed-type guard")

local descriptor = operation("schedule-target", { session_id = "s", window_id = "w1" })
assert(descriptor.backend == "rex" and descriptor.target.block_id == "b1")
assert(not descriptor.target.window_id and descriptor.guard.instance_id == instance)
views.s.windows[1].focused_block_id = "b2"
result = operation("job-send", descriptor.target, { guard = descriptor.guard, text = "scheduled literal $HOME", enter = true })
assert(result.sent == 1 and sent_ids() == "b1", "schedule resolves one exact pane at submit time")
for _, call in ipairs(call_log) do assert(call.method ~= "client.perform", "scheduled sends never change app focus") end
instance = "server-run-two"
local sent, send_error = pcall(operation, "job-send", descriptor.target, { guard = descriptor.guard, text = "must not send" })
assert(not sent and tostring(send_error):find("restarted or changed", 1, true))
assert(sent_ids() == "", "server restart guard must run before input")
local no_guard = pcall(operation, "job-send", descriptor.target, { text = "unguarded" })
assert(not no_guard and sent_ids() == "")
print("passed: exact scheduled target, no app focus, server-instance refusal")

views.s.active_window_id = "w2"
local exact = operation("preview", { session_id = "s", block_id = "b1" })
assert(exact.target.window_id == "w1", "a later active window must not overwrite the exact pane's window")
operation("zoom", { session_id = "s", block_id = "b1" }, { zoom = true })
local selected
for _, call in ipairs(call_log) do if call.method == "client.perform" then selected = call.args.args end end
assert(selected and selected.window_id == "w1", "zoom must select the window containing the requested pane")
local stale, stale_error = pcall(operation, "preview", { session_id = "s", window_id = "w2", block_id = "b1" })
assert(not stale and tostring(stale_error):find("moved to another window", 1, true))
local missing, missing_error = pcall(operation, "preview", { session_id = "s", window_id = "w1", block_id = "gone" })
assert(not missing and tostring(missing_error):find("pane no longer exists", 1, true),
  "a missing pane must not be reported as a missing existing window")
views.s.active_window_id = "w1"
print("passed: exact pane window resolution independent of active window ordering")

operation("create", nil, { name = "new-project", cwd = "/project", startup_lines = { "echo '$HOME' $(literal)", "C-c" } })
local data = {}
for _, call in ipairs(call_log) do
  if call.method == "com.superlogical.terminal.write" then
    assert(call.args.block_id == "fresh-pane", "startup must only reach the newly-created first pane")
    data[#data + 1] = call.args.args.data
  end
  assert(call.method ~= "block.event", "startup key-looking text must remain literal")
end
assert(startup_polls == 2 and #data == 2)
assert(data[1] == "echo '$HOME' $(literal)\r" and data[2] == "C-c\r")
assert(operation("health", nil).lines[1]:find("OK Rex", 1, true))
print("passed: new-shell readiness, literal startup lines, native health")
