-- Rex owns the floating terminal and completion; Rust owns the shared picker.
local M = {}

local function readable(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

local function rex_binary(options)
  local explicit = options.rex_binary or os.getenv("INTERDIMUX_REX_BIN")
  if explicit and explicit ~= "" then return explicit end
  for directory in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    local path = directory .. "/rex"
    if readable(path) then return path end
  end
  local suffix = "/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
  local parents = { "/Applications", (os.getenv("HOME") or "") .. "/Applications" }
  for _, parent in ipairs(parents) do
    for _, app in ipairs({ "Rex Beta.app", "Rex.app" }) do
      local path = parent .. "/" .. app .. suffix
      if readable(path) then return path end
    end
  end
  error("Cannot find the Rex CLI; set INTERDIMUX_REX_BIN", 0)
end

function M.setup(options)
  options = options or {}
  local root = assert(options.root, "interdimux.setup requires its checkout root")
  local binary = options.binary or os.getenv("INTERDIMUX_BIN") or (root .. "/rust/target/release/imux")
  local dashboard_ui = options.dashboard_ui or "terminal"
  assert(dashboard_ui == "terminal" or dashboard_ui == "native", "interdimux dashboard_ui must be native or terminal")
  local width, height = options.width or 0.78, options.height or 0.66
  assert(type(width) == "number" and width > 0 and width <= 1, "interdimux width must be a fraction from 0 to 1")
  assert(type(height) == "number" and height > 0 and height <= 1, "interdimux height must be a fraction from 0 to 1")
  local jobs = {}

  local function app_context(ctx, arguments)
    -- A configuration action sees its caller's connection. In `rex -C APP
    -- do interdimux` that is the short-lived CLI, not APP: -C only routes the
    -- client actions queued in the action's reply. Our detached coordinator
    -- needs the persistent app ID explicitly before creating any float.
    local client_id = arguments and arguments.client_id or ctx.client_id
    local listed, list_error = rex.call("client.list", { kinds = { "app" } })
    if not listed then error(list_error, 0) end
    for _, client in ipairs(listed.clients or {}) do
      if client.client_id == client_id and client.connection_state ~= "lost" then
        local context = {}
        for key, value in pairs(ctx) do context[key] = value end
        context.client_id = client_id
        return context
      end
    end
    error("Interdimux needs a connected Rex app client. Open it from the app, or pass client_id=<app ID> to rex do; -C is not exposed to configuration actions.", 0)
  end

  local function launch(ctx, mode)
      if not ctx.client_id or not ctx.session_id or not ctx.block_id then
        error("Open interdimux from a focused Rex pane", 0)
      end
      if not readable(binary) then
        error("Build interdimux first: cd " .. root .. "/rust && cargo build --release --locked", 0)
      end
      local view, view_error = rex.session.view { session_id = ctx.session_id }
      if not view then error(view_error, 0) end
      local origin
      for _, window in ipairs(view.windows or {}) do
        for _, layer in ipairs(window.layers or {}) do
          for _, block in ipairs(layer.blocks or {}) do
            if block.block_id == ctx.block_id then origin = window end
          end
        end
      end
      if not origin then error("The originating Rex pane no longer exists", 0) end
      for _, layer in ipairs(origin.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if layer.kind == "floating" and block.label == "interdimux" and block.owner == ctx.client_id then
            local process = rex.call("com.superlogical.terminal.process", {
              session_id = ctx.session_id, block_id = block.block_id, args = {},
            })
            local child = process and process.child
            local executable = child and (child.path or child.invoked_path or child.argv0 or child.name) or ""
            local basename = executable:gsub(" %(deleted%)$", ""):match("([^/]+)$")
            if basename == "imux" or basename == binary:match("([^/]+)$") then
              local focused, focus_error = rex.session.set_layer_state {
                session_id = ctx.session_id, layer_id = layer.layer_id, state = "normal", focus = true,
              }
              if not focused then error(focus_error, 0) end
              return
            end
          end
        end
      end
      -- A picker in another session/window must not lock this hotkey out.
      -- Suppress only duplicate launches while this origin's pane is pending.
      local key = ctx.client_id .. "|" .. ctx.session_id .. "|" .. origin.window_id
      local previous = jobs[key]
      if previous then
        local checked, running = pcall(function() return previous:running() end)
        if checked and running then return end
      end
      local args = {
        root = root, binary = binary, client_id = ctx.client_id,
        session_id = ctx.session_id, window_id = origin.window_id,
        block_id = ctx.block_id, origin_zoomed_block_id = origin.zoomed_block_id,
        bounds = { (1 - width) / 2, (1 - height) / 2, width, height },
        mode = mode,
      }
      local job, start_error = rex.exec.start({
        rex_binary(options), "--autostart=false", "--color=never", "--timeout=10s",
        "do", root .. "/integrations/rex_coordinator.lua", "--args", rex.json.encode(args),
      }, {
        -- A detached coordinator must not retain callbacks into this action's
        -- Lua lifetime. It reports failures through its own native notice.
        detach = true, stdout = false, stderr = false,
        env = { REX_SESSION = false, REX_BLOCK = false, REX_CLIENT = false },
      })
      if not job then error(start_error, 0) end
      jobs[key] = job
  end
  local function register(name, title, mode)
    rex.action {
      name = name, title = "Interdimux: " .. title, category = "Interdimux",
      description = "Interdimux's shared " .. mode .. " picker",
      keywords = "interdimux imux mux " .. mode,
      args = { client_id = "string?" },
      run = function(ctx, arguments) launch(app_context(ctx, arguments), mode) end,
    }
  end
  register("interdimux", "Switch Session, Window or Pane", "switch")
  if dashboard_ui == "terminal" then
    register("interdimux_dashboard", "Dashboard", "dashboard")
  end
  register("interdimux_agents", "Agents Needing Attention", "agents")
  register("interdimux_rename", "Rename Sessions, Windows or Panes", "rename")
  register("interdimux_kill", "Close Sessions, Windows or Panes", "kill")
  register("interdimux_swap", "Swap Windows or Panes", "swap")
  register("interdimux_zoom", "Zoom Panes", "zoom")
  register("interdimux_send", "Send Text or Keys", "send")
  register("interdimux_dirs", "Open Project Directory", "dirs")
  register("interdimux_schedule", "Schedule Text or Keys", "schedule")
  register("interdimux_jobs", "Scheduled Jobs", "jobs")
  register("interdimux_health", "Check Setup", "doctor")
  rex.bind(options.key or "ctrl+b>f", "interdimux")
  -- The native palette owns its presentation and dismissal. Do not start a
  -- hidden terminal picker behind it, or resume one when Escape is pressed.
  rex.bind(options.dashboard_key or "ctrl+b>g",
    dashboard_ui == "native" and "client.palette.toggle" or "interdimux_dashboard")

  local function direct(ctx, verb, extra)
    if not ctx.client_id or not ctx.session_id or not ctx.block_id then error("Run interdimux from a focused Rex pane", 0) end
    local view = assert(rex.session.view { session_id = ctx.session_id })
    local window_id
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == ctx.block_id then window_id = window.window_id end
        end
      end
    end
    if not window_id then error("The originating Rex pane no longer exists", 0) end
    local command = { binary, verb, "--backend", "rex", "--client", ctx.client_id,
      "--session", ctx.session_id, "--window", window_id, "--block", ctx.block_id }
    for _, value in ipairs(extra or {}) do command[#command + 1] = value end
    local result, err = rex.exec(command, { env = { REX_SESSION = false, REX_BLOCK = false, REX_CLIENT = false } })
    if not result then error(err, 0) end
    if not result.ok then error(result.stderr or "Interdimux action failed", 0) end
  end
  rex.action { name = "interdimux_agent_next", title = "Interdimux: Next Agent Needing Attention", category = "Interdimux",
    keywords = "interdimux imux mux agent next attention",
    args = { client_id = "string?" },
    run = function(ctx, arguments) direct(app_context(ctx, arguments), "agent-next") end }
  if options.agent_next_key then rex.bind(options.agent_next_key, "interdimux_agent_next") end
  local function jump(index)
    local name = "interdimux_jump_" .. index
    rex.action { name = name, title = "Interdimux: Session " .. index, category = "Interdimux",
      keywords = "interdimux imux mux session jump",
      args = { client_id = "string?" },
      run = function(ctx, arguments) direct(app_context(ctx, arguments), "jump", { tostring(index) }) end }
    rex.bind("ctrl+b>" .. index, name)
  end
  if options.jump_keys then
    for index = 1, math.max(1, math.min(9, tonumber(options.jump_keys) or 9)) do jump(index) end
  end
end

return M
