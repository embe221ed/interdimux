-- Delivery eligibility and exit races through the actual operation module.
-- lua tests/rex_send_guards.lua [root] [alternate-operations-for-baseline]
local root = arg[1] or "."
local operate = dofile(arg[2] or (root .. "/integrations/rex_operations.lua"))
local getenv = os.getenv
local views, processes, calls, reads, context, on_process, on_input
local function live(pid, executable)
  return { child = { pid = pid, path = executable or "/bin/zsh" },
    foreground = { pid = pid, name = "zsh" } }
end
local function block(id, label)
  return { block_id = id, label = label or id, creator_name = "com.superlogical.terminal" }
end
local function reset()
  calls, reads, processes = {}, {}, { shell = live(10), other = live(20) }
  on_process, on_input = nil, nil
  os.getenv = getenv
  context = { session_id = "s", window_id = "w1", block_id = "shell",
    picker_block_id = "own-picker", client_id = "app:a", binary = "/opt/custom-picker" }
  views = { s = { session_id = "s", active_window_id = "w1", windows = {
    { window_id = "w1", focused_block_id = "shell", layers = { { blocks = { block("shell") } } } },
    { window_id = "w2", focused_block_id = "other", layers = { { blocks = { block("other") } } } },
  } } }
end
rex = { call = function(method, args)
  calls[#calls + 1] = { method = method, args = args }
  if method == "session.view" then return views[args.session_id] end
  if method == "server.status" then return { instance_id = "instance", host_id = "host" } end
  if method == "com.superlogical.terminal.process" then
    reads[args.block_id] = (reads[args.block_id] or 0) + 1
    if on_process then on_process(args.block_id, reads[args.block_id]) end
    return processes[args.block_id] or {}, nil
  end
  if method == "com.superlogical.terminal.format" then return { content = "retained output" } end
  if method == "com.superlogical.terminal.write" or method == "block.event" then
    if on_input then on_input(method, args) end
  end
  return {}
end }
local function operation(name, target, args)
  return operate({ operation = name, target = target or { session_id = "s", block_id = "shell" },
    args = args or {} }, context)
end
local function input_ids()
  local ids = {}
  for _, call in ipairs(calls) do
    if call.method == "com.superlogical.terminal.write" or call.method == "block.event" then
      ids[#ids + 1] = call.args.block_id
    end
  end
  table.sort(ids)
  return table.concat(ids, ",")
end
local function rejected(name, target, args, message)
  local ok, result = pcall(operation, name, target, args)
  assert(not ok, "expected delivery refusal")
  assert(tostring(result):find(message, 1, true), tostring(result))
  assert(input_ids() == "", "a refused preflight must not type anywhere")
end
local failures = {}
local function test(name, run)
  reset()
  local ok, result = pcall(run)
  if ok then print("passed: " .. name)
  else failures[#failures + 1] = name; print("FAILED: " .. name .. ": " .. tostring(result)) end
end

test("parent sends omit every verified picker across clients and windows", function()
  local first = views.s.windows[1].layers[1].blocks
  for _, id in ipairs({ "own-picker", "second-picker", "custom-picker", "deleted-picker", "spoof", "renamed" }) do
    first[#first + 1] = block(id, id == "renamed" and "work" or "interdimux")
  end
  -- Different owners must not affect whether a hidden picker receives input.
  first[3].owner = "app:b"
  processes["second-picker"] = live(30, "/opt/imux")
  processes["custom-picker"] = live(31, "/opt/custom-picker")
  processes["deleted-picker"] = live(32, "/opt/imux (deleted)")
  processes.spoof = live(33, "/bin/cat")
  processes.spoof.child.argv0 = "imux"
  processes.renamed = live(34, "/opt/imux")
  views.s.windows[2].layers[1].blocks[2] = block("far-picker", "interdimux")
  processes["far-picker"] = live(35, "/opt/imux")
  local sent = operation("send", { session_id = "s" }, { text = "literal" })
  assert(sent.sent == 4 and input_ids() == "other,renamed,shell,spoof", input_ids())
  assert(not reads["own-picker"], "do not inspect the invoking picker")
end)

test("window sends use executable precedence and configured binary names", function()
  local first = views.s.windows[1].layers[1].blocks
  first[2] = block("picker", "interdimux")
  processes.picker = { child = { pid = 30, path = "", invoked_path = "/opt/env-picker", argv0 = "cat" } }
  os.getenv = function(key) if key == "INTERDIMUX_BIN" then return "/custom/env-picker" end; return getenv(key) end
  assert(operation("send", { session_id = "s", window_id = "w1" }, { key = "ctrl+c" }).sent == 1)
  assert(input_ids() == "shell")
end)

test("exact and scheduled picker targets are refused", function()
  views.s.windows[1].layers[1].blocks[2] = block("picker", "interdimux")
  processes.picker = live(30, "/opt/imux")
  for _, name in ipairs({ "send", "schedule-target" }) do
    calls = {}
    rejected(name, { session_id = "s", block_id = "picker" }, { text = "must not type" }, "picker cannot receive")
  end
end)

test("retained exited terminal rejects text, keys and Enter", function()
  processes.shell = { last_exit = { exit_code = 7 } }
  for _, args in ipairs({ { text = "not executed", enter = true }, { key = "ctrl+c" }, { text = "", enter = true } }) do
    calls = {}
    rejected("send", nil, args, "terminal has exited")
  end
end)

test("exited schedule submission and due-time delivery fail before input", function()
  processes.shell = { last_exit = { exit_code = 7 } }
  rejected("schedule-target", nil, {}, "terminal has exited")
  calls = {}
  rejected("job-send", nil, { guard = { instance_id = "instance", host_id = "host" },
    text = "must not run", enter = true }, "terminal has exited")
end)

test("mixed parent target preflights all recipients before input", function()
  processes.other = { last_exit = { exit_code = 0 } }
  rejected("send", { session_id = "s" }, { text = "must not partially send" }, "terminal has exited")
end)

test("unknown and replaced receiving processes refuse input", function()
  processes.shell = {}
  rejected("send", nil, { text = "unknown" }, "Cannot verify")
  processes.shell = live(10)
  reads, calls = {}, {}
  on_process = function(id, count) if id == "shell" and count == 2 then processes.shell = live(11) end end
  rejected("send", nil, { text = "replacement" }, "process changed")
end)

test("exit before write is skipped, exit after write is uncertain without Enter", function()
  on_process = function(id, count)
    if id == "shell" and count == 2 then processes.shell = { last_exit = { exit_code = 0 } } end
  end
  rejected("send", nil, { text = "not delivered", enter = true }, "terminal has exited")
  reset()
  on_input = function() processes.shell = { last_exit = { exit_code = 0 } } end
  local ok, message = pcall(operation, "send", nil, { text = "maybe delivered", enter = true })
  assert(not ok and tostring(message):find("Input may have been delivered; do not retry automatically", 1, true), tostring(message))
  assert(input_ids() == "shell", "do not send Enter or retry after the receiver exits")
end)

test("live shell survives foreground change and an earlier last_exit", function()
  processes.shell.last_exit = { exit_code = 0 }
  on_input = function() processes.shell.foreground = { pid = 99, name = "new-command" } end
  assert(operation("send", nil, { text = "command", enter = true }).sent == 1)
  assert(input_ids() == "shell,shell")
end)

test("capture and close remain available for retained terminal output", function()
  processes.shell = { last_exit = { exit_code = 7 } }
  assert(operation("preview", nil).text == "retained output")
  operation("close", nil)
  assert(calls[#calls].method == "block.close")
end)

os.getenv = getenv
assert(#failures == 0, table.concat(failures, "; "))
