-- Local AppKit entry points; terminal actions remain available separately.
local M = {}

local function encode(value)
  return (value:gsub("[^A-Za-z0-9._~-]", function(byte)
    return string.format("%%%02X", byte:byte())
  end))
end

local function readable(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

function M.setup(options)
  options = options or {}
  local root = assert(options.root, "interdimux_macos.setup requires its checkout root")
  local app = root .. "/macos/build/Interdimux Picker.app"
  local function launch(ctx, arguments, host)
    if not ctx.session_id or not ctx.block_id then error("Open the native picker from a focused Rex pane", 0) end
    local client_id = arguments and arguments.client_id or ctx.client_id
    local listed, list_error = rex.call("client.list", { kinds = { "app" } })
    if not listed then error(list_error, 0) end
    local local_app = false
    for _, client in ipairs(listed.clients or {}) do
      if client.client_id == client_id and client.connection_state ~= "lost" then
        local principal, info = client.principal or {}, client.info or {}
        local_app = info.platform == "macos" and principal.kind == "peer" and principal.transport == "unix"
          and (principal.path == nil or (type(principal.path) == "table" and next(principal.path) == nil))
      end
    end
    if not local_app then
      error("The native picker requires a local macOS Rex app. Remote server launch is unsupported; CLI callers must pass client_id=<local app ID> (-C is not action context).", 0)
    end
    local view, view_error = rex.session.view { session_id = ctx.session_id }
    if not view then error(view_error, 0) end
    local window_id
    for _, window in ipairs(view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.block_id == ctx.block_id then window_id = window.window_id end
        end
      end
    end
    if not window_id then error("The originating Rex pane no longer exists", 0) end
    -- The hotkey already proved the exact local app and origin. Launch
    -- Services can deliver its URL directly, without two Python startups,
    -- another client-list CLI, or a source-tree walk on every keypress.
    -- open.sh --check-build remains the explicit development staleness audit.
    for _, file in ipairs({ "MacOS/InterdimuxPicker", "Helpers/imux", "Resources/build-stamp" }) do
      if not readable(app .. "/Contents/" .. file) then
        error("Build the native picker first: " .. root .. "/macos/build.sh", 0)
      end
    end
    local url = "interdimux-picker://" .. host .. "?client_id=" .. encode(client_id)
      .. "&session_id=" .. encode(ctx.session_id) .. "&window_id=" .. encode(window_id)
      .. "&block_id=" .. encode(ctx.block_id)
    local job, launch_error = rex.exec.start({ "/usr/bin/open", "-g", "-a", app, url,
    }, {
      detach = true, stdout = false, stderr = false,
      env = { REX_CLIENT = false, REX_SESSION = false, REX_WINDOW = false, REX_BLOCK = false, REX_SERVER = false },
    })
    if not job then error(launch_error, 0) end
  end
  local function register(name, title, description, host)
    rex.action {
      name = name, title = "Interdimux: " .. title,
      category = "Interdimux", keywords = "interdimux imux native macos " .. host,
      description = description, args = { client_id = "string?" },
      run = function(ctx, arguments) launch(ctx, arguments, host) end,
    }
  end
  register("interdimux_macos", "Native macOS Picker", "Search and switch sessions, tabs and panes", "open")
  register("interdimux_macos_dashboard", "Native macOS Dashboard", "Open Interdimux actions and tools", "dashboard")
  rex.bind(options.key or "ctrl+b>f", "interdimux_macos")
  rex.bind(options.dashboard_key or "ctrl+b>g", "interdimux_macos_dashboard")
end

return M
