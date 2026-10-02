-- tests/run.lua — drives the REAL fleet/ state machine against simulated CC APIs.
-- Proves: dispatch, allowlist, idempotency, halt, safe-dig guards, error taxonomy.
-- Run:  lua5.1 tests/run.lua

-- ---------------------------------------------------------------------------
-- Simulated CC:Tweaked environment (only what fleet/ touches)
-- ---------------------------------------------------------------------------
local WORLD = {
  blocks = {},          -- "x,y,z" -> {name=..., state=...}
  turtle = { x = 0, y = 64, z = 0 },
  fuel = 500,
  items = {},           -- slot -> {name=..., count=...}
}

-- Fill an empty world; place a wall one block ahead (z-1) to test obstruction,
-- and an unbreakable block to test that path too.
local function key(x,y,z) return x..","..y..","..z end
WORLD.blocks[key(0,64,-1)] = { name = "minecraft:stone" }
WORLD.blocks[key(0,64,-2)] = { name = "minecraft:bedrock" }   -- dig fails

local turtleApi = {}
local moveCount = 0

function turtleApi.getFuelLevel() return WORLD.fuel end
function turtleApi.getFuelLimit() return 20000 end
function turtleApi.getItemCount(slot)
  local it = WORLD.items[slot]
  return it and it.count or 0
end
function turtleApi.getItemDetail(slot)
  local it = WORLD.items[slot]
  if not it then return nil end
  return { name = it.name, count = it.count }
end
function turtleApi.getItemSpace(slot) return 64 - turtleApi.getItemCount(slot) end

----- movement: forward is blocked by a block at z-1 UNLESS it was dug
local function blocked(x,y,z) return WORLD.blocks[key(x,y,z)] ~= nil end

function turtleApi.forward()
  local t = WORLD.turtle
  if blocked(t.x, t.y, t.z - 1) then return false, "Movement obstructed" end
  t.z = t.z - 1; moveCount = moveCount + 1; WORLD.fuel = WORLD.fuel - 1
  return true
end
function turtleApi.back()
  local t = WORLD.turtle
  if blocked(t.x, t.y, t.z + 1) then return false, "Movement obstructed" end
  t.z = t.z + 1; moveCount = moveCount + 1; WORLD.fuel = WORLD.fuel - 1
  return true
end
function turtleApi.up()
  local t = WORLD.turtle
  if blocked(t.x, t.y + 1, t.z) then return false, "Movement obstructed" end
  t.y = t.y + 1; moveCount = moveCount + 1; WORLD.fuel = WORLD.fuel - 1
  return true
end
function turtleApi.down()
  local t = WORLD.turtle
  if blocked(t.x, t.y - 1, t.z) then return false, "Movement obstructed" end
  t.y = t.y - 1; moveCount = moveCount + 1; WORLD.fuel = WORLD.fuel - 1
  return true
end
function turtleApi.turnLeft()  WORLD.facing = (WORLD.facing or 0) end
function turtleApi.turnRight() WORLD.facing = (WORLD.facing or 0) end

function turtleApi.inspect()
  local t = WORLD.turtle
  local b = WORLD.blocks[key(t.x, t.y, t.z - 1)]
  if not b then return false end
  return true, { name = b.name, state = b.state or {} }
end
function turtleApi.inspectUp()
  local t = WORLD.turtle
  local b = WORLD.blocks[key(t.x, t.y + 1, t.z)]
  if not b then return false end
  return true, { name = b.name, state = b.state or {} }
end
function turtleApi.inspectDown()
  local t = WORLD.turtle
  local b = WORLD.blocks[key(t.x, t.y - 1, t.z)]
  if not b then return false end
  return true, { name = b.name, state = b.state or {} }
end

function turtleApi.dig()
  local t = WORLD.turtle
  local k = key(t.x, t.y, t.z - 1)
  local b = WORLD.blocks[k]
  if not b then return false, "Nothing to dig here" end
  if b.name == "minecraft:bedrock" then return false, "Cannot break" end
  WORLD.blocks[k] = nil
  for s = 1, 16 do
    if not WORLD.items[s] then WORLD.items[s] = { name = b.name, count = 1 }; return true end
  end
  return false, "No space for items"
end
function turtleApi.digUp()    -- simplified: mirror of dig on the up face
  local t = WORLD.turtle
  local k = key(t.x, t.y + 1, t.z)
  local b = WORLD.blocks[k]
  if not b then return false, "Nothing to dig here" end
  if b.name == "minecraft:bedrock" then return false, "Cannot break" end
  WORLD.blocks[k] = nil
  return true
end
function turtleApi.digDown()
  local t = WORLD.turtle
  local k = key(t.x, t.y - 1, t.z)
  local b = WORLD.blocks[k]
  if not b then return false, "Nothing to dig here" end
  if b.name == "minecraft:bedrock" then return false, "Cannot break" end
  WORLD.blocks[k] = nil
  return true
end

function turtleApi.refuel(slot)
  if slot then
    local it = WORLD.items[slot]
    if not it then return false, "Nothing to refuel" end
    WORLD.fuel = WORLD.fuel + 10
    return true
  end
  local any = false
  for s = 1, 16 do
    if WORLD.items[s] then WORLD.fuel = WORLD.fuel + 10; any = true end
  end
  return any
end

-- ---------------------------------------------------------------------------
-- Simulated CC globals
-- ---------------------------------------------------------------------------
local QUEUE, NOW = {}, 1000000
local SENT = {}

function os.epoch(tz) return NOW end
function os.getComputerID() return 2 end
function os.getComputerLabel() return "T01" end
function os.sleep(s) NOW = NOW + math.floor(s * 1000) end
function os.startTimer(s) return 1 end
function os.queueEvent(...) QUEUE[#QUEUE+1] = { ... } end
function os.pullEvent(filter)
  while true do
    if #QUEUE > 0 then
      local e = table.remove(QUEUE, 1)
      if not filter or e[1] == filter then return table.unpack(e) end
    else
      return nil
    end
  end
end

textutils = {}
function textutils.serialiseJSON(t)
  local function enc(v)
    local ty = type(v)
    if ty == "nil" then return "null"
    elseif ty == "boolean" then return tostring(v)
    elseif ty == "number" then return tostring(v)
    elseif ty == "string" then return '"'..v:gsub('"','\\"')..'"'
    elseif ty == "table" then
      -- detect array vs object (CC emits {} for an empty table)
      local isArr, n = true, 0
      for k in pairs(v) do
        n = n + 1
        if type(k) ~= "number" then isArr = false end
      end
      if n == 0 then return "{}" end
      if isArr then
        local parts = {}
        for i = 1, n do parts[i] = enc(v[i]) end
        return "["..table.concat(parts, ",").."]"
      end
      local parts = {}
      for k, val in pairs(v) do parts[#parts+1] = '"'..tostring(k)..'":'..enc(val) end
      return "{"..table.concat(parts, ",").."}"
    end
    return "null"
  end
  return enc(t)
end

-- minimal JSON decoder sufficient for the payloads the tests send
function textutils.unserialiseJSON(s)
  if type(s) ~= "string" then return nil end
  local pos = 1
  local function skip() while pos <= #s and s:sub(pos,pos):match("%s") do pos = pos + 1 end end
  local parseValue
  local function parseString()
    pos = pos + 1
    local out = {}
    while pos <= #s do
      local c = s:sub(pos,pos)
      if c == '"' then pos = pos + 1; return table.concat(out) end
      if c == "\\" then
        local n = s:sub(pos+1,pos+1)
        out[#out+1] = (n == "n" and "\n") or (n == "t" and "\t") or n
        pos = pos + 2
      else
        out[#out+1] = c; pos = pos + 1
      end
    end
    return nil
  end
  local function parseNumber()
    local st = pos
    while pos <= #s and s:sub(pos,pos):match("[%d%.%-eE%+]") do pos = pos + 1 end
    return tonumber(s:sub(st, pos-1))
  end
  parseValue = function()
    skip()
    local c = s:sub(pos,pos)
    if c == "{" then
      pos = pos + 1; local obj = {}
      skip()
      if s:sub(pos,pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip(); local k = parseString()
        skip(); pos = pos + 1 -- ':'
        obj[k] = parseValue()
        skip()
        local d = s:sub(pos,pos); pos = pos + 1
        if d == "}" then break end
      end
      return obj
    elseif c == "[" then
      pos = pos + 1; local arr = {}
      skip()
      if s:sub(pos,pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr+1] = parseValue()
        skip()
        local d = s:sub(pos,pos); pos = pos + 1
        if d == "]" then break end
      end
      return arr
    elseif c == '"' then return parseString()
    elseif s:sub(pos,pos+3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos,pos+4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos,pos+3) == "null" then pos = pos + 4; return nil
    else return parseNumber() end
  end
  local ok, v = pcall(parseValue)
  if not ok then return nil end
  return v
end

fs = {}
function fs.open(path, mode)
  return nil   -- no token file in tests (bridge disabled)
end
function fs.exists() return false end

peripheral = {
  getType = function(side) if side == "left" then return "modem" end return nil end,
  call = function(side, method) if method == "isWireless" then return true end end,
}

rednet = {
  open = function() end,
  broadcast = function() end,
  send = function(id, msg, proto) SENT[#SENT+1] = { to = id, msg = msg, proto = proto } end,
  receive = function(proto, timeout) return nil, nil end,
  _SENT = SENT,
}

turtle = turtleApi

http = { websocket = function() return nil, "disabled in tests" end }

-- make `require("fleet.x")` resolve
local realRequire = require
_G.require = function(name)
  local path = name:gsub("%.", "/") .. ".lua"
  local f = io.open(path, "r")
  if not f then error("module not found: " .. path) end
  f:close()
  return realRequire(name)
end
package.path = "./?.lua;" .. package.path

