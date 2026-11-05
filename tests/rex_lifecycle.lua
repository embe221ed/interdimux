-- Native lifecycle regression tests without a Rex server or any UI mutation.
-- Run from the checkout: lua tests/rex_lifecycle.lua [checkout-root]
local root = arg[1] or "."
local actual_dofile = dofile

local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function fixture(scenario)
  local directory = os.tmpname()
  os.remove(directory)
  local made = os.execute("mkdir " .. shell_quote(directory))
  assert(made == true or made == 0, "cannot create private test directory")
  local handlers, layers, restored, readiness = {}, {}, {}, {}
  local stopped
  local stop_marker = {}
  local snapshot = {
    version = 1, sessions = { { session_id = "session:origin", label = "work" } },
    views = { ["session:origin"] = { windows = {} } }, errors = {}, metadata = {},
  }

  rex = {
    args = {
      root = root, binary = "/unused/imux", client_id = "client:origin",
      session_id = "session:origin", window_id = "window:origin",
      block_id = "block:origin", origin_zoomed_block_id = "block:origin",
    },
    exec = function()
      if scenario == "prepare_error" then return nil, "mock preparation failure" end
      return { ok = true, stdout = directory .. "\n" }
    end,
    on = function(name, callback) handlers[name] = callback end,
    every = function() return { cancel = function() end } end,
    stop = function(code) stopped = code or 0; error(stop_marker, 0) end,
    log = function() end,
    layout = { block = function(block) return { block = block } end },
    call = function(method)
      assert(method == "com.superlogical.terminal.size", "startup must not perform GUI actions")
      return { owner = "cli", columns = 80, rows = 24 }
    end,
    session = {
      attach = function() return {} end,
      view = function() return snapshot.views["session:origin"] end,
      disown_block = function() return {} end,
      close_layer = function() return {} end,
      new_layer = function(layer)
        assert(handlers["terminal.child_exited"] and handlers.block_closed,
          "subscribe before opening any picker or error notice")
        assert(layer.layout.block.options.login == false)
        if #layers == 0 and scenario ~= "prepare_error" then
          local pending = assert(io.open(directory .. "/ready.json", "rb"))
          pending:close()
          assert(not io.open(directory .. "/snapshot.json", "rb"),
            "create the float before collecting its snapshot so GUI startup overlaps metadata")
        end
        layers[#layers + 1] = layer
        return { layer_id = "layer:" .. #layers, block_ids = { "block:" .. #layers } }
      end,
    },
    json = {
      encode = function(value)
        if type(value) == "table" and type(value.ready) == "boolean" then
          readiness[#readiness + 1] = value.ready
        end
        return "snapshot"
      end,
      decode = function(text)
        if text == "error" then return { version = 1, outcome = "error", message = "mock Rust error" } end
        if text == "stale" then
          return { version = 1, outcome = "select", target = {
            session_id = "session:other", window_id = "window:other", block_id = "block:gone",
          } }
        end
        error("invalid mock result", 0)
      end,
    },
  }

  dofile = function(path)
    if path == root .. "/rust/src/rex_snapshot.lua" then
      assert(#layers == 1, "snapshot collection should overlap the new float's startup")
      assert(rex.args.picker_block_id == "block:1", "exclude the picker from its own metadata")
      return snapshot
    end
    if path == root .. "/rust/src/rex_activate.lua" then
      return function(payload)
        if not payload.restore then error("The selected pane is gone", 0) end
        assert(payload.client_id == "client:origin")
        assert(payload.session_id == "session:origin")
        assert(payload.block_id == "block:origin")
        assert(payload.origin_zoomed_block_id == "block:origin")
        restored[#restored + 1] = payload
      end
    end
    return actual_dofile(path)
  end

  local loaded, load_error = pcall(actual_dofile, root .. "/integrations/rex_coordinator.lua")
  assert(loaded, tostring(load_error))
  assert(stopped == nil, "keep the coordinator alive while its terminal is visible")
  if scenario ~= "prepare_error" then
    assert(#readiness == 2 and readiness[1] == false and readiness[2] == true,
      "publish ready as soon as the snapshot exists, even while CLI still owns the terminal")
  end

  local function fire(name, block_id)
    local returned, event_error = pcall(handlers[name], {}, { block_id = block_id, exit_code = 1 })
    assert(returned or event_error == stop_marker, tostring(event_error))
  end
  local function result(text)
    local file = assert(io.open(directory .. "/result.json", "wb"))
    file:write(text); file:close()
  end

  if scenario == "rust_error" then
    result("error")
    assert(#restored == 0 and stopped == nil, "an early error record must not dismiss the acknowledgement")
    fire("terminal.child_exited", "block:1")
    assert(stopped == 0 and #restored == 1, "acknowledged Rust error restores origin and saved zoom")
  elseif scenario == "stale_target" then
    result("stale")
    fire("terminal.child_exited", "block:1")
    assert(#layers == 2 and stopped == nil and #restored == 0,
      "a failed activation keeps its native error notice focused")
    fire("block_closed", "block:1")
    assert(stopped == nil and #restored == 0, "old picker close must not dismiss the notice")
    fire("terminal.child_exited", "block:2")
    assert(stopped == 1 and #restored == 1, "notice acknowledgement restores origin and saved zoom")
  else
    assert(#layers == 1 and #restored == 0, "preparation error opens an owned notice")
    fire("block_closed", "block:1")
    assert(stopped == 1 and #restored == 1, "early error notice dismissal restores saved zoom")
  end
  dofile = actual_dofile
  os.remove(directory .. "/result.json")
  os.remove(directory .. "/snapshot.json")
  os.remove(directory)
end

for _, scenario in ipairs({ "rust_error", "stale_target", "prepare_error" }) do
  fixture(scenario)
  print("passed: " .. scenario)
end
