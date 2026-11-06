-- Shared hosted/direct history, tested entirely in memory without a Rex server.
local root = arg[1] or "."
local real_dofile, real_open = dofile, io.open
local helper_file = assert(real_open(root .. "/rust/src/rex_history.lua", "rb"))
local helper_source = helper_file:read("*a"); helper_file:close()
local files, encoded, serial, reads = {}, {}, 0, {}
local history_path = "/private-state/interdimux/rex-mru.json"
local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local function encode(value)
  serial = serial + 1; local key = "json:" .. serial
  encoded[key] = copy(value); return key
end
local function disk() return copy(encoded[files[history_path]]) end
files[history_path] = encode { version=1,last=100,sessions={ ["session:origin"]=90,["session:hosted"]=100 },
  paths={ ["session:hosted"]="/original/project" } }
io.open = function(path, mode)
  if mode == "rb" then
    reads[path] = (reads[path] or 0) + 1
    if not files[path] then return end
    return { read=function() return files[path] end, close=function() return true end }
  end
  assert(mode == "wb")
  return { write=function(_, text) files[path]=text; return true end, close=function() return true end }
end
os.getenv = function(key) if key == "XDG_STATE_HOME" then return "/private-state" elseif key == "HOME" then return "/home/local" end end
os.rename = function(from, to)
  if from == to then return nil, "file exists" end -- macOS directory rename
  if files[from] then files[to]=files[from]; files[from]=nil end
  return true
end
os.remove = function(path) files[path]=nil; return true end
os.time = function() return 100 end
local handlers, timer, stopped, commands = {}, nil, nil, {}
local principal = { kind="peer",transport="unix",pid=123,uid=501 }
local snapshot = { version=1,host_id="host:local",sessions={
  {session_id="session:origin",label="origin"},{session_id="session:hosted",label="hosted"}},
  views={},metadata={},errors={} }
rex = {
  args={root=root,binary="/unused/imux",client_id="client:origin",session_id="session:origin",window_id="window:origin",block_id="block:origin"},
  json={encode=encode,decode=function(text) return copy(assert(encoded[text],"invalid mock JSON")) end},
  exec=function(command) commands[#commands+1]=command; return {ok=true,stdout="/private-picker\n"} end,
  call=function(method)
    if method == "server.whoami" then return {principal=principal} end
    if method == "server.status" then return {host_id="host:local"} end
    error("Unexpected API: " .. method)
  end,
  on=function(name, callback) handlers[name]=callback end,
  every=function(_, callback) timer=callback; return {cancel=function() end} end,
  stop=function(code) stopped=code or 0 end,
  log=function() end,
  layout={block=function(value) return value end},
  session={attach=function() return {} end,disown_block=function() return {} end,
    new_layer=function() return {layer_id="layer:picker",block_ids={"block:picker"}} end,
    close_layer=function() return {} end},
}
dofile = function(path)
  if path == root .. "/rust/src/rex_snapshot.lua" then return copy(snapshot) end
  if path == root .. "/rust/src/rex_activate.lua" then return function() end end
  if path == root .. "/integrations/rex_geometry.lua" then
    return {initial=function() end,observe=function(_,_,_,callback)
      callback {columns=80,rows=24,cell_width_px=10,cell_height_px=20}
      return {cancel=function() end}
    end}
  end
  if path == root .. "/integrations/rex_operations.lua" then
    return function(request) assert(request.operation=="create");return {target={session_id="session:new-hosted"}} end
  end
  return real_dofile(path)
end
real_dofile(root .. "/integrations/rex_coordinator.lua")
assert(reads[history_path] == 1, "opening must reuse its initial history read")
assert(#commands == 1 and commands[1][1] == "mktemp",
  "existing history and grid directories must not spawn mkdir on macOS")
assert(disk().sessions["session:origin"] == 101)
local helper = assert(load("local imux_collector_pid,imux_collector_uid=123,501\n" .. helper_source))()
local direct = helper.enrich {host_id="host:local",local_host_id="host:local"}
assert(direct.mru["session:origin"] == 101 and direct.session_paths["session:hosted"] == "/original/project")
helper.remember("session:direct", "/direct/project", "session:origin")
assert(disk().sessions["session:direct"] > disk().sessions["session:origin"])
assert(disk().paths["session:direct"] == "/direct/project")
files["/private-picker/request.json"] = encode {version=1,id=1,operation="create",args={cwd="/hosted/project"}}
assert(timer); timer()
assert(disk().paths["session:direct"] == "/direct/project", "hosted creation must preserve a direct update")
assert(disk().paths["session:new-hosted"] == "/hosted/project")
helper.remember("session:later", "/later/project")
files["/private-picker/result.json"] = encode {version=1,outcome="select",target={session_id="session:hosted"}}
handlers["terminal.child_exited"]({}, {block_id="block:picker",exit_code=0})
assert(stopped==0 and disk().paths["session:later"] == "/later/project", "hosted selection must merge a later direct update")
assert(disk().sessions["session:hosted"] == disk().last)
local before, count = files[history_path], reads[history_path]
principal.path={"login-server"}; helper.remember("remote", "/wrong")
assert(files[history_path] == before and reads[history_path] == count, "forwarded peer must not read or write local history")
assert(helper.enrich {host_id="remote"}.mru == nil and reads[history_path] == count)
principal.path=nil; principal.pid=124; helper.remember("wrong-process", "/wrong")
assert(files[history_path] == before and reads[history_path] == count)
principal.pid=123; principal.transport="tcp"; helper.remember("tcp", "/wrong")
assert(files[history_path] == before and reads[history_path] == count)
-- The configuration runs on the server, so it needs no CLI-locality probe.
local config_history = helper.for_server_config()
rex.call = function(method) error("Config history must not make API calls: " .. method) end
rex.exec = function() error("An initialized history directory needs no process") end
config_history.remember("session:fast", "session:hosted", "client:keyboard")
local fast = config_history.read()
assert(fast.sessions["session:fast"] == fast.last)
assert(fast.sessions["session:hosted"] == fast.last - 1)
assert(fast.paths["session:later"] == "/later/project", "keyboard toggles must preserve project metadata")
print("passed: direct/hosted MRU, creation directories, merge, bounded initial reads, local-only persistence")
print("passed: server configuration shares history without CLI probes or subprocesses")
