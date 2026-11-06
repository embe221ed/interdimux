-- Native operations used by the persistent coordinator and direct CLI fallback.
-- All identity is supplied as full Rex IDs; labels are presentation only.
return function(request, context)
  local operation = request.operation
  local target = request.target
  local options = request.args or {}
  local function call(method, args)
    local result, err = rex.call(method, args)
    if result == nil then error(err, 0) end
    return result
  end
  local function terminal(method, pane, args)
    return call("com.superlogical.terminal." .. method, {
      session_id = pane.session_id, block_id = pane.block_id, args = args or {},
    })
  end
  local function locate(candidate)
    if type(candidate) ~= "table" or type(candidate.session_id) ~= "string" then
      error("Select an existing Rex target", 0)
    end
    local view = call("session.view", { session_id = candidate.session_id })
    local window, block
    for _, w in ipairs(view.windows or {}) do
      -- An exact pane determines its own window. The active window may come
      -- later in the list and must not overwrite a pane we already found.
      if candidate.window_id == w.window_id or (not candidate.block_id
          and not candidate.window_id and view.active_window_id == w.window_id) then
        window = w
      end
      for _, layer in ipairs(w.layers or {}) do
        for _, b in ipairs(layer.blocks or {}) do
          if candidate.block_id == b.block_id then
            if candidate.window_id and candidate.window_id ~= w.window_id then
              error("The selected Rex pane moved to another window; reload the list", 0)
            end
            window, block = w, b
          end
        end
      end
    end
    if candidate.window_id and not window then error("The selected Rex window no longer exists", 0) end
    if candidate.block_id and not block then error("The selected Rex pane no longer exists", 0) end
    if block and block.block_id == context.picker_block_id then error("The picker cannot act on itself", 0) end
    return view, window, block
  end
  local function pane(candidate)
    local view, window, block = locate(candidate)
    if not block and window then
      local focused = window.focused_block_id
      if focused == context.picker_block_id then focused = context.block_id end
      for _, layer in ipairs(window.layers or {}) do
        for _, b in ipairs(layer.blocks or {}) do
          if b.block_id ~= context.picker_block_id and (not block or b.block_id == focused) then block = b end
        end
      end
    end
    if not block then error("This target has no available pane", 0) end
    return { session_id = view.session_id or candidate.session_id,
      window_id = window.window_id, block_id = block.block_id }, block, view, window
  end
  local function select(p)
    return call("client.perform", { client_id = context.client_id,
      action = "session.select", args = { session_id = p.session_id, window_id = p.window_id },
      origin = "cli", timeout_ms = 5000,
    })
  end
  local function disown(session_id, blocks)
    call("session.attach", { session_id = session_id })
    call("session.disown_block", { session_id = session_id, block_ids = blocks })
  end
  local function shell(cwd)
    return rex.layout.block { flavor = "com.superlogical.terminal.shell", options = { cwd = cwd } }
  end
  local function hydrate(p, lines)
    if lines == nil then return end
    if type(lines) ~= "table" then error("Startup commands must be literal lines", 0) end
    for _, line in ipairs(lines) do
      if type(line) ~= "string" or line:find("[%z\r\n]") then error("Startup commands must be separate literal lines", 0) end
    end
    if #lines == 0 then return end
    -- Only an explicit new-session action enters this path. Wait for the new
    -- shell, never for ordinary picker rendering or an existing session.
    local shells = { sh=true, bash=true, zsh=true, fish=true, dash=true, ksh=true, mksh=true, tcsh=true, csh=true, nu=true, pwsh=true }
    local stable, last, ready = 0, nil, false
    for attempt = 1, 40 do
      local process = terminal("process", p)
      local fg = process.foreground
      local name = fg and (fg.name or ""):gsub("^%-", "")
      local identity = fg and tostring(fg.pid) .. ":" .. name
      if shells[name] then
        if identity == last then stable = stable + 1 else stable = 0; last = identity end
        local modes = terminal("modes", p)
        for _, mode in ipairs(modes.modes or {}) do
          if mode.name == "bracketed_paste" and mode.set then ready = true end
        end
        if ready or (attempt >= 7 and stable >= 5) then ready = true; break end
      else stable = 0; last = nil end
      rex.sleep(.05)
    end
    if not ready then error("The new session's shell is not ready for startup commands", 0) end
    for _, line in ipairs(lines) do
      if line ~= "" then terminal("write", p, { data = line .. "\r" }) end
    end
  end

  if operation == "snapshot" then return {} end
  if operation == "health" then
    local server = call("server.status", {})
    local found, client = pcall(call, "client.inspect", { client_id = context.client_id })
    local origin = rex.call("session.view", { session_id = context.session_id })
    return { lines = {
      "OK Rex server instance: " .. tostring(server.instance_id or "unknown"),
      "OK API revision: " .. tostring(server.api_revision or "unknown"),
      (found and client and "OK" or "WARN") .. " initiating app client: " .. tostring(context.client_id or "unavailable"),
      (origin and "OK" or "WARN") .. " origin session: " .. tostring(context.session_id or "unavailable"),
      "OK native labels, panes, splits, verified program status, guarded scheduled sends",
      "INFO Rex does not support tmux client detach or cross-session swaps",
    } }
  elseif operation == "schedule-target" then
    local p, block, view, window = pane(target)
    if block.creator_name ~= "com.superlogical.terminal" then error("Schedule requires a terminal pane", 0) end
    local server = call("server.status", {})
    if type(server.instance_id) ~= "string" or server.instance_id == "" then error("Rex cannot guard this scheduled command's server identity", 0) end
    return { backend = "rex", target = { session_id = p.session_id, block_id = p.block_id },
      guard = { instance_id = server.instance_id, host_id = server.host_id },
      label = tostring(view.label or p.session_id) .. " / " .. tostring(window.label or p.window_id) .. " / " .. tostring(block.label or p.block_id) }
  elseif operation == "job-send" then
    local guard = options.guard
    if type(guard) ~= "table" or type(guard.instance_id) ~= "string" or guard.instance_id == "" then
      error("The scheduled Rex command has no server identity guard", 0)
    end
    local server = call("server.status", {})
    if server.instance_id ~= guard.instance_id or (guard.host_id and server.host_id ~= guard.host_id) then
      error("The Rex server restarted or changed; the scheduled command was skipped", 0)
    end
    if not target or not target.block_id then error("A scheduled command requires one exact pane", 0) end
    operation = "send"
  end
  if operation == "rename" then
    locate(target)
    if type(options.name) ~= "string" then error("Enter a new name", 0) end
    local args = { session_id = target.session_id, label = options.name }
    if target.block_id then args.block_id = target.block_id; call("session.set_block_label", args)
    elseif target.window_id then args.window_id = target.window_id; call("session.set_window_label", args)
    else call("session.set_label", args) end
    return {}
  elseif operation == "close" then
    locate(target)
    if context.hosted and not context.finished and target.session_id == context.session_id
        and (target.block_id == context.block_id or (not target.block_id
          and (not target.window_id or target.window_id == context.window_id))) then
      error("Closing the picker origin must finish the picker first", 0)
    end
    if target.block_id then call("block.close", { session_id = target.session_id, block_id = target.block_id })
    elseif target.window_id then call("session.close_window", { session_id = target.session_id, window_id = target.window_id })
    else call("session.destroy", { session_id = target.session_id }) end
    return {}
  elseif operation == "zoom" then
    local p = pane(target)
    select(p)
    local zoom = options.zoom
    if zoom == nil and context.hosted then
      zoom = not (p.session_id == context.session_id and p.block_id == context.origin_zoomed_block_id)
    end
    call("session.zoom_block", { session_id = p.session_id, block_id = p.block_id, zoom = zoom })
    return { target = p }
  elseif operation == "swap" then
    local other = options.other
    local first_window = target and target.window_id and not target.block_id
    local other_window = other and other.window_id and not other.block_id
    if first_window and other_window then
      if target.session_id ~= other.session_id then error("Rex swaps windows only within the same session", 0) end
      local view = locate(target)
      locate(other)
      if target.window_id == other.window_id then return {} end
      local first, second
      for index, window in ipairs(view.windows or {}) do
        if window.window_id == target.window_id then first = index end
        if window.window_id == other.window_id then second = index end
      end
      local low, high, low_index, high_index
      -- Use explicit endpoints: the installed Rex Lua VM evaluates
      -- `a,b=b,a` as a=old_b,b=old_b, unlike standard Lua.
      if first < second then
        low = target.window_id; high = other.window_id
        low_index = first; high_index = second
      else
        low = other.window_id; high = target.window_id
        low_index = second; high_index = first
      end
      local after = view.windows[high_index + 1] and view.windows[high_index + 1].window_id
      -- Place the high window before the low one, then the low window at the
      -- old high position. Native move_window leaves active window/focus intact.
      call("session.move_window", { session_id = target.session_id, window_id = high, before_window_id = low })
      -- Adjacent windows are already swapped by that first move. In
      -- particular, do not ask Rex to move the last window before itself.
      if high_index > low_index + 1 then
        call("session.move_window", { session_id = target.session_id, window_id = low, before_window_id = after })
      end
      return {}
    end
    if not (target and target.block_id and other and other.block_id) then
      error("Swap requires two windows or two panes", 0)
    end
    local first = pane(target)
    local second = pane(other)
    if first.session_id ~= second.session_id then error("Rex swaps panes only within the same session", 0) end
    call("session.swap_blocks", { session_id = first.session_id,
      block_id = first.block_id, other_block_id = second.block_id })
    return {}
  elseif operation == "send" then
    local recipients = {}
    if target and target.block_id then
      local p, block = pane(target)
      if block.creator_name ~= "com.superlogical.terminal" then error("Send requires a terminal pane", 0) end
      recipients[1] = p
    else
      local view = locate(target)
      for _, window in ipairs(view.windows or {}) do
        if not target.window_id or target.window_id == window.window_id then
          for _, layer in ipairs(window.layers or {}) do
            for _, block in ipairs(layer.blocks or {}) do
              if block.creator_name == "com.superlogical.terminal" and block.block_id ~= context.picker_block_id then
                recipients[#recipients + 1] = { session_id = target.session_id,
                  window_id = window.window_id, block_id = block.block_id }
              end
            end
          end
        end
      end
    end
    if #recipients == 0 then error("This target has no terminal panes to send to", 0) end
    for _, p in ipairs(recipients) do
    if options.text ~= nil then
      if type(options.text) ~= "string" then error("Send text must be a string", 0) end
      terminal("write", p, { data = options.text })
    end
    local function key(value)
      if type(value) ~= "string" then error("Send key must be a key name", 0) end
      local modifiers, name = {}, nil
      local aliases = { control = "ctrl", option = "alt", opt = "alt", cmd = "super", command = "super", meta = "super" }
      -- In ctrl++ the final plus is the key, while the first separates it
      -- from its modifier. A bare plus is also a key, not an empty list.
      local plus = value == "+" or value:sub(-2) == "++"
      local parts = plus and value:sub(1, -2) or value
      for rawpart in parts:lower():gmatch("[^+]+") do
        local part = aliases[rawpart] or rawpart
        if part == "ctrl" or part == "alt" or part == "shift" or part == "super" then modifiers[part] = true
        elseif name then error("Send accepts one key at a time", 0)
        else name = part end
      end
      if plus then
        if name then error("Send accepts one key at a time", 0) end
        name = "+"
      end
      local named = { enter = "enter", ["return"] = "enter", escape = "escape", esc = "escape",
        tab = "tab", space = "space", backspace = "backspace", delete = "delete", insert = "insert",
        up = "arrow_up", down = "arrow_down", left = "arrow_left", right = "arrow_right",
        home = "home", ["end"] = "end", pageup = "page_up", pagedown = "page_down" }
      local physical, text, codepoint = named[name], "", 0
      if not physical and name and name:match("^f%d+$") and tonumber(name:sub(2)) >= 1 and tonumber(name:sub(2)) <= 25 then physical = name end
      if not physical and name and #name == 1 then
        local punctuation = { ["-"]="minus",["="]="equal",["["]="bracket_left",["]"]="bracket_right",
          [";"]="semicolon",["'"]="quote",[","]="comma",["."]="period",["/"]="slash",["\\"]="backslash",["`"]="backquote" }
        local shifted = { ["`"]="~",["1"]="!",["2"]="@",["3"]="#",["4"]="$",["5"]="%",
          ["6"]="^",["7"]="&",["8"]="*",["9"]="(",["0"]=")",["-"]="_",["="]="+",
          ["["]="{",["]"]="}",["\\"]="|",[";"]=":",["'"]='"',[","]="<",["."]=">",["/"]="?" }
        local base = name
        for unshifted, symbol in pairs(shifted) do
          if name == symbol then base = unshifted; modifiers.shift = true; break end
        end
        physical = base:match("^[a-z]$") and ("key_" .. base)
          or base:match("^%d$") and ("digit_" .. base) or punctuation[base]
        codepoint = base:byte()
        if not modifiers.ctrl and not modifiers.super then
          text = modifiers.shift and (shifted[base] or base:upper()) or base
        end
      end
      if not physical then error("Unsupported key name: " .. tostring(name), 0) end
      local mods = {}
      for _, modifier in ipairs({ "shift", "ctrl", "alt", "super" }) do if modifiers[modifier] then mods[#mods + 1] = modifier end end
      call("block.event", { session_id = p.session_id, block_id = p.block_id,
        event = { type = "key", payload = { key = physical, mods = table.concat(mods, "+"),
          consumed_mods = "", text = text, unshifted_codepoint = codepoint, composing = false, action = "press" } } })
    end
    if options.key then key(options.key) end
    if options.enter then key("enter") end
    end
    return { sent = #recipients }
  elseif operation == "create" then
    local kind = options.kind or "session"
    if kind == "session" then
      local made = call("session.create", { label = options.name,
        initial_windows = { { layout = shell(options.cwd) } } })
      local window = made.initial_windows[1]
      disown(made.session_id, window.block_ids)
      hydrate({ session_id = made.session_id, window_id = window.window_id, block_id = window.block_ids[1] }, options.startup_lines)
      return { target = { session_id = made.session_id } }
    elseif kind == "window" then
      locate(target)
      local made = call("session.new_window", { session_id = target.session_id,
        window_label = options.name, layout = shell(options.cwd), focus = false })
      disown(target.session_id, made.block_ids)
      return { target = { session_id = target.session_id, window_id = made.window_id } }
    end
    error("Create supports a session or window", 0)
  elseif operation == "split" then
    local p, block = pane(target)
    local directions = {
      right = { "horizontal", "after" }, left = { "horizontal", "before" },
      down = { "vertical", "after" }, up = { "vertical", "before" },
      below = { "vertical", "after" }, above = { "vertical", "before" },
    }
    local direction = directions[options.direction or "right"]
    if not direction then error("Choose right, left, up or down for a split", 0) end
    local cwd = options.cwd
    if not cwd and block.creator_name == "com.superlogical.terminal" then
      local process = terminal("process", p)
      cwd = process.foreground and process.foreground.cwd or process.child and process.child.cwd
    end
    local made = call("session.new_split", { session_id = p.session_id, anchor_id = p.block_id,
      direction = direction[1], side = direction[2], focus = false, layout = shell(cwd) })
    disown(p.session_id, made.block_ids)
    return { target = { session_id = p.session_id, window_id = p.window_id, block_id = made.block_ids[1] } }
  elseif operation == "preview" then
    local p, block = pane(target)
    if block.creator_name ~= "com.superlogical.terminal" then
      return { text = block.label or block.flavor or "This pane has no terminal preview" }
    end
    local formatted = terminal("format", p, { format = "text", trim = true, unwrap = true, max_bytes = 32768 })
    local text = formatted.content or ""
    if formatted.id then
      local tail = terminal("blob_read", p, { id = formatted.id,
        offset = math.max(0, (formatted.total or #text) - 32768), max_bytes = 983040 })
      text = tail.data or text
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
    local count = math.max(1, math.min(200, tonumber(options.lines) or 24))
    local first = math.max(1, #lines - count + 1)
    return { text = table.concat(lines, "\n", first), target = p }
  end
  if operation == "detach" then error("Rex has no tmux-style detach action; switch sessions or close the app window", 0) end
  error("Unsupported Rex operation: " .. tostring(operation), 0)
end
