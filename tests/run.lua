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

-- ---------------------------------------------------------------------------
-- Test driver
-- ---------------------------------------------------------------------------
local pass, fail = 0, 0
local failures = {}

local LAST_RESP
local function check(name, cond, extra)
  if cond then
    pass = pass + 1
    print(("  [pass] %s"):format(name))
  else
    fail = fail + 1
    failures[#failures+1] = name
    local dbg = ""
    if LAST_RESP then
      dbg = ("  <- %s | err=%s | detail=%s"):format(tostring(extra), tostring(LAST_RESP.error), tostring(LAST_RESP.detail))
    else
      dbg = extra and ("  <- " .. tostring(extra)) or ""
    end
    print(("  [FAIL] %s%s"):format(name, dbg))
  end
end

print("=== fleet Phase-1 logic tests (simulated CC:Tweaked) ===")
print()

local config = require("fleet.config")   -- provides the module for state.lua
local net    = require("fleet.net")
local E      = require("fleet.errors")
local vmod   = require("fleet.verbs")
local state  = require("fleet.state")

local s = state.new()
local ctx = { state = s, inventoryFreeSlots = state.inventoryFreeSlots, telemetry = state.telemetry }

local function send(action, args)
  local id = "T01-test-" .. tostring(os.epoch("utc")) .. "-" .. action
  local msg = { v = 1, id = id, action = action, args = args or {} }
  local v = net.validate(msg)
  assert(v, "validate failed for " .. action)
  local resp = state.dispatch(s, ctx, v)
  LAST_RESP = resp
  return resp, id
end

----------------------------------------------------------------------------
print("1. identity + turtle detection")
check("selfId() uses the CC label", state.selfId() == "T01", state.selfId())
check("requireTurtle() passes with turtle api", (state.requireTurtle()) == true)
check("modem found on 'left'", state.openModem() == "left")

----------------------------------------------------------------------------
print("2. status telemetry")
local r = send("status")
check("status ok", r.ok == true, r.error)
check("telemetry carries turtle id", r.state and r.state.turtle == "T01")
check("telemetry carries fuel", r.state and r.state.fuel == 500, r.state and r.state.fuel)
check("telemetry carries free slots", r.state and r.state.inventoryFreeSlots == 16)
check("telemetry marks pos estimated", r.state and r.state.pos and r.state.pos.estimated == true)

----------------------------------------------------------------------------
print("3. movement, and the obstruction path")
-- wall at z-1: forward must fail with movement_obstructed
local before = moveCount
r = send("forward")
check("forward into wall -> ok=false", r.ok == false)
check("reason is movement_obstructed", r.error == E.MOVEMENT_OBSTRUCTED, r.error)
check("turtle did NOT move", moveCount == before, moveCount - before)
check("detail carries the reason", type(r.detail) == "string")

-- turn, then verify turning never consumes fuel or moves
local f0 = WORLD.fuel
r = send("turn_right")
check("turn_right ok", r.ok == true)
check("turn reports facing", r.result and r.result.facing == 1, r.result and r.result.facing)
check("turning consumed no fuel", WORLD.fuel == f0, WORLD.fuel - f0)

----------------------------------------------------------------------------
print("4. digging, and safe-dig guards")
r = send("dig")
check("dig of stone ok", r.ok == true, r.error)
check("dig reports what it dug", r.result and r.result.dug == "minecraft:stone", r.result and r.result.dug)
check("wall is gone", WORLD.blocks["0,64,-1"] == nil)

-- now forward should succeed
r = send("forward")
check("forward after dig -> ok", r.ok == true, r.error)
check("turtle moved exactly one block", moveCount == before + 1, moveCount - before)

-- next block is bedrock: dig must refuse with unbreakable_block
local t = WORLD.turtle
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = { name = "minecraft:bedrock" }
r = send("dig")
check("dig bedrock -> ok=false", r.ok == false)
check("reason is unbreakable_block", r.error == E.UNBREAKABLE_BLOCK, r.error)
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil

-- dig with nothing in front
r = send("dig")
check("dig of air -> nothing_to_dig", r.ok == false and r.error == E.NOTHING_TO_DIG, r.error)

----------------------------------------------------------------------------
print("5. inspection")
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = { name = "minecraft:gravel" }
r = send("inspect")
check("inspect ok", r.ok == true, r.error)
check("inspect names the block", r.result and r.result.block == "minecraft:gravel", r.result and r.result.block)
r = send("inspect_up")
check("inspect_up on air -> nothing_to_inspect", r.ok == false and r.error == E.NOTHING_TO_INSPECT, r.error)

----------------------------------------------------------------------------
print("6. fuel and inventory reporting")
r = send("fuel")
check("fuel ok", r.ok == true and r.result.fuel == WORLD.fuel, r.result and r.result.fuel)
r = send("inventory")
check("inventory ok", r.ok == true, r.error)
check("inventory reports free slots", r.result and r.result.freeSlots == 15, r.result and r.result.freeSlots)

----------------------------------------------------------------------------
print("7. out-of-fuel guard")
local saved = WORLD.fuel
WORLD.fuel = 0
r = send("forward")
check("forward at 0 fuel -> out_of_fuel", r.ok == false and r.error == E.OUT_OF_FUEL, r.error)
check("state latched out_of_fuel", s.out_of_fuel == true)
WORLD.fuel = saved
r = send("refuel", { slot = 1 })
check("refuel clears the latch", s.out_of_fuel == false, r.error)

----------------------------------------------------------------------------
print("8. inventory-full guard")
-- fill every slot
local keep = WORLD.items
WORLD.items = {}
for i = 1, 16 do WORLD.items[i] = { name = "minecraft:cobblestone", count = 64 } end
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = { name = "minecraft:stone" }
r = send("dig")
check("dig when full -> inventory_full", r.ok == false and r.error == E.INVENTORY_FULL, r.error)
check("state latched inventory_full", s.inventory_full == true)
WORLD.items = keep
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil

----------------------------------------------------------------------------
print("9. ALLOWLIST — no arbitrary code execution")
r = send("os.execute")
check("unknown action refused", r.ok == false and r.error == E.UNSUPPORTED_ACTION, r.error)
r = send("dofile")
check("dofile refused", r.ok == false and r.error == E.UNSUPPORTED_ACTION, r.error)
r = send("loadstring")
check("loadstring refused", r.ok == false and r.error == E.UNSUPPORTED_ACTION, r.error)
r = send("__proto__")
check("odd key refused", r.ok == false and r.error == E.UNSUPPORTED_ACTION, r.error)
-- the allowlist is a closed set: every verb is a table with fn
local bad = 0
for k, v in pairs(vmod) do
  if type(v) ~= "table" or type(v.fn) ~= "function" then bad = bad + 1 end
end
check("every allowlisted verb is callable, nothing else exposed", bad == 0, bad)

----------------------------------------------------------------------------
print("10. malformed input")
local v = net.validate({ v = 1, id = "", action = "forward" })
check("empty id rejected", v == nil)
v = net.validate({ v = 1, id = "x", action = "" })
check("empty action rejected", v == nil)
v = net.validate({ v = 99, id = "x", action = "forward" })
check("wrong protocol version rejected", v == nil)
v = net.validate({ v = 1, id = "x", action = "forward", args = "notatable" })
check("non-table args rejected", v == nil)
v = net.validate({ v = 1, id = "x", action = "forward" })
check("well-formed message accepted", v ~= nil)
local d, derr = net.decode("{{{not json")
check("garbage does not decode to a table", d == nil, derr)
d, derr = net.decode(string.rep("x", 40000))
check("oversized payload refused", d == nil and derr == "too_large", derr)

----------------------------------------------------------------------------
print("11. IDEMPOTENCY — the critical property")
local dedupe = net.newDedupe(config.DEDUPE_SIZE)
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil   -- clear path
local moveBefore = moveCount
local cmdId = "T01-idem-001"

local msg = net.validate({ v = 1, id = cmdId, action = "forward" })
-- first execution
local first
if not dedupe:get(cmdId) then
  first = state.dispatch(s, ctx, msg); dedupe:put(cmdId, first)
end
local movedOnce = moveCount - moveBefore
-- DELIBERATE RETRY: controller re-sends the same id
local replay
if not dedupe:get(cmdId) then
  replay = state.dispatch(s, ctx, msg); dedupe:put(cmdId, replay)
end
replay = replay or dedupe:get(cmdId)
local movedTotal = moveCount - moveBefore

check("first command moved the turtle", movedOnce == 1, movedOnce)
check("retried id did NOT move again", movedTotal == 1, movedTotal)
check("replay returned the cached response", replay and replay.id == cmdId, replay and replay.id)
check("replay preserved ok=true", replay and replay.ok == true)

-- a NEW id must execute
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil
local id2 = "T01-idem-002"
local m2 = net.validate({ v = 1, id = id2, action = "forward" })
if not dedupe:get(id2) then local rr = state.dispatch(s, ctx, m2); dedupe:put(id2, rr) end
check("a different id DOES execute", moveCount - moveBefore == 2, moveCount - moveBefore)

----------------------------------------------------------------------------
print("12. stop / halt semantics")
r = send("stop")
check("stop ok", r.ok == true, r.error)
check("stop latched halted", s.halted == true)
r = send("forward")
check("movement refused while halted", r.ok == false and r.error == E.HALTED, r.error)
r = send("dig")
check("dig refused while halted", r.ok == false and r.error == E.HALTED, r.error)
r = send("status")
check("status still allowed while halted", r.ok == true, r.error)
r = send("resume")
check("resume ok", r.ok == true, r.error)
check("halt cleared", s.halted == false)
local moveResume = moveCount
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil
r = send("forward")
check("movement works after resume", r.ok == true and moveCount == moveResume + 1, r.error)

----------------------------------------------------------------------------
print("13. stuck detection (mechanical, not string matching)")
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = { name = "minecraft:obsidian" }
s.stuck_count, s.last_failed_action, s.mode = 0, nil, "idle"
for i = 1, 3 do send("forward") end
check("3 consecutive obstructions -> stuck state", s.mode == "stuck", s.mode)
check("stuck_count tracked", s.stuck_count == 3, s.stuck_count)
WORLD.blocks[(t.x)..","..(t.y)..","..(t.z - 1)] = nil
r = send("forward")
check("a successful move clears stuck", s.mode == "idle" and s.stuck_count == 0, s.mode)

----------------------------------------------------------------------------
print("14. JSON round trip (CC quirks)")
local enc = net.encode({ v = 1, id = "a", action = "status", args = {} })
check("empty args table serialises", enc ~= nil, enc)
local dec = net.decode(enc)
check("round trip preserves id", dec and dec.id == "a", dec and dec.id)
check("empty table decodes to a table", dec and type(dec.args) == "table")
local rt = net.decode(net.encode({ ok = true, n = 42, s = "hi" }))
check("booleans survive", rt and rt.ok == true)
check("numbers survive", rt and rt.n == 42, rt and rt.n)
check("strings survive", rt and rt.s == "hi")
-- "unlimited" fuel string must not crash the guard
local savedFuel = WORLD.fuel
turtleApi.getFuelLevel = function() return "unlimited" end
r = send("fuel")
check('fuel "unlimited" handled', r.ok == true and r.result.fuel == "unlimited", r.result and r.result.fuel)
r = send("forward")
check("movement allowed when fuel is unlimited", r.ok == true, r.error)
turtleApi.getFuelLevel = function() return WORLD.fuel end
WORLD.fuel = savedFuel

----------------------------------------------------------------------------
print()
print(("="):rep(66))
if fail == 0 then
  print(("ALL %d CHECKS PASSED"):format(pass))
else
  print(("%d passed, %d FAILED"):format(pass, fail))
  for _, n in ipairs(failures) do print("  failed: " .. n) end
end
print(("="):rep(66))
os.exit(fail == 0 and 0 or 1)
