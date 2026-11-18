-- layout and focus are the same functions the one-shot commands use.
local catalog = layout()
if not (rex.json and rex.json.encode and rex.json.decode and io and io.lines and io.write and io.flush) then
  return catalog
end

local function emit(value)
  io.write(rex.json.encode(value), "\n")
  io.flush()
end

-- Distinguish this live reader from an older CLI returning only its layout.
catalog.imux_focus_connection = true
emit(catalog)
for line in io.lines() do
  rex.args = rex.json.decode(line)
  local ok, result = pcall(focus)
  emit(ok and result or {error = tostring(result)})
end
