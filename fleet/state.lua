-- fleet/state.lua — the turtle: identity, state machine, dispatch, telemetry.
-- Owns: how to execute, how to dig safely, fuel, inventory-full, recovery,
--       reporting success/failure/status. Never: what work to do, or when.

local config = requireModule("config")
local net    = requireModule("net")
local E      = requireModule("errors")
local verbs  = requireModule("verbs")

local state = {}

-- ---- identity -----------------------------------------------------------

-- Persistent id: prefer the CC label (survives reboots), then config, then id.
function state.selfId()
  local label = os.getComputerLabel()
  if config.TURTLE_ID then return config.TURTLE_ID end
  if label and #label > 0 then return label end
  return "T" .. tostring(os.getComputerID())
end

-- Verify we're actually on a turtle before doing anything else.
function state.requireTurtle()
  if type(turtle) ~= "table" then return nil, E.TURTLE_API_MISSING end
  return true
end

-- ---- modem --------------------------------------------------------------

-- Prefer a WIRED modem when TRANSPORT is "wired" (or when asked for explicitly):
-- wired networks have no length cap and are storm-proof, wireless is capped at
-- 64 blocks. Falls back to any modem rather than refusing to run, because a
-- first test with a wireless modem should still work.
local function findModem()
  local sides = { "left", "right", "top", "bottom", "front", "back" }
  local function isModem(side) return peripheral.getType(side) == "modem" end
  local function isWireless(side)
    local ok, res = pcall(peripheral.call, side, "isWireless")
    return ok and res and true or false
  end

  if config.TRANSPORT ~= "wireless" then
    for _, side in ipairs(sides) do
      if isModem(side) and not isWireless(side) then return side end
    end
  end
  for _, side in ipairs(sides) do
    if isModem(side) then return side end
  end
  return nil
end

function state.openModem()
  local side = findModem()
  if not side then return nil, "no_modem" end
  rednet.open(side)
  return side
end

-- ---- state --------------------------------------------------------------

function state.new()
  return {
    id = state.selfId(),
    mode = "idle",
    fuel = nil,
    inventoryFreeSlots = 16,
    lastCommand = nil,
    lastError = nil,
    pos = { x = nil, y = nil, z = nil, estimated = true },
    facing = 0,               -- 0=north 1=east 2=south 3=west (dead-reckoned)
    halted = false,
    stuck_count = 0,
    last_failed_action = nil,
    out_of_fuel = false,
    inventory_full = false,
    bootEpoch = os.epoch("utc"),
    stopped = false,          -- set by the stop handler to break the loop
  }
end

function state.inventoryFreeSlots()
  local used = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then used = used + 1 end
  end
  return 16 - used
end

function state.fuelLevel()
  local f = turtle.getFuelLevel()
  if type(f) == "string" then return f end   -- "unlimited"
  return f
end

-- Telemetry blob, attached to every response so the registry stays fresh free.
function state.telemetry(s)
  return {
    turtle = s.id,
    state = s.mode,
    fuel = s.fuel,
    inventoryFreeSlots = s.inventoryFreeSlots,
    lastCommand = s.lastCommand,
    lastError = s.lastError,
    pos = s.pos,
    facing = s.facing,
    halted = s.halted,
    out_of_fuel = s.out_of_fuel,
    inventory_full = s.inventory_full,
    bootEpoch = s.bootEpoch,
    ts = os.epoch("utc"),
  }
end

-- ---- dispatch -----------------------------------------------------------

-- Latched conditions gate dispatch. Only `stop` is unconditional, and only
-- `resume`, `status` and `stop` are allowed while halted: a queued command
-- must not be able to defeat a halt.
local function gated(s, action)
  if not s.halted then return false end
  if action == "stop" or action == "resume" or action == "status" or action == "fuel" then
    return false
  end
  return true
end

-- Execute one validated command. ALWAYS returns a response table.
-- pcall-wrapped: the turtle must never die from network input.
function state.dispatch(s, ctx, msg)
  local entry = verbs[msg.action]
  if type(entry) ~= "table" or type(entry.fn) ~= "function" then
    return { v = 1, id = msg.id, turtle = s.id, ok = false,
             error = E.UNSUPPORTED_ACTION, detail = msg.action, state = state.telemetry(s) }
  end

  if gated(s, msg.action) then
    return { v = 1, id = msg.id, turtle = s.id, ok = false,
             error = E.HALTED, state = state.telemetry(s) }
  end

  ctx.args = msg.args or {}
  local ok, r1, r2, r3 = pcall(entry.fn, ctx)

  if not ok then
    s.lastError = E.INTERNAL_ERROR
    return { v = 1, id = msg.id, turtle = s.id, ok = false,
             error = E.INTERNAL_ERROR, detail = tostring(r1), state = state.telemetry(s) }
  end

  s.lastCommand = msg.action

  if r1 == true then
    s.lastError = nil
    s.stuck_count = 0
    s.mode = "idle"
    s.fuel = state.fuelLevel()
    s.inventoryFreeSlots = ctx.inventoryFreeSlots()
    return { v = 1, id = msg.id, turtle = s.id, ok = true,
             result = r2 or {}, state = state.telemetry(s) }
  end

  -- Failure. Track repeated obstruction at the same action to detect "stuck".
  local err = r2 or E.INTERNAL_ERROR
  s.lastError = err
  if err == E.MOVEMENT_OBSTRUCTED then
    if s.last_failed_action == msg.action then
      s.stuck_count = s.stuck_count + 1
      if s.stuck_count >= 3 then s.mode = "stuck" end
    else
      s.last_failed_action = msg.action
      s.stuck_count = 1
    end
  else
    s.stuck_count = 0
    s.last_failed_action = msg.action
  end

  return { v = 1, id = msg.id, turtle = s.id, ok = false,
           error = err, detail = r3, state = state.telemetry(s) }
end

-- ---- main loop ----------------------------------------------------------

-- Announce on every boot: there is no persistent session (§3.3 of DESIGN).
function state.announce(s, controllerId)
  rednet.broadcast({ v = 1, type = "hello", turtle = s.id, state = state.telemetry(s) },
                   config.ANNOUNCE_PROTOCOL)
  if controllerId then
    rednet.send(controllerId, { v = 1, type = "hello", turtle = s.id, state = state.telemetry(s) },
                config.ANNOUNCE_PROTOCOL)
  end
end

function state.run(s, opts)
  opts = opts or {}
  local controllerId = opts.controllerId or config.CONTROLLER_ID
  local ctx = {
    state = s,
    inventoryFreeSlots = state.inventoryFreeSlots,
    telemetry = state.telemetry,      -- verbs.status needs this
  }

  local dedupe = net.newDedupe(config.DEDUPE_SIZE)
  local lastHeartbeat = os.epoch("utc")

  while not s.stopped do
    -- Blocking wait, but bounded so heartbeat + stop checks still happen.
    -- Never a busy-wait loop: computer_threads=1, max_main_computer_time=5ms.
    local sender, raw = rednet.receive(config.PROTOCOL, config.COMMAND_TIMEOUT_MS / 1000)

    -- Stop channel: unconditional, latches halted.
    -- (rednet.receive above only returns our protocol; poll the stop protocol
    --  non-blockingly so a halt cannot be blocked behind a full queue.)
    local _, stopRaw = rednet.receive(config.STOP_PROTOCOL, 0)
    if stopRaw then
      local stopMsg = net.decode(stopRaw)
      if type(stopMsg) == "table" and stopMsg.type == "stop" then
        if stopMsg.scope == "fleet" or stopMsg.turtle == nil or stopMsg.turtle == s.id then
          s.halted = true
          s.mode = "halted"
          state.announce(s, controllerId)
        end
      end
    end

    if raw ~= nil then
      local msg, derr = net.decode(raw)
      if msg == nil then
        -- Malformed: report, do not crash. No id to echo, so synthesise one.
        rednet.send(sender, { v = 1, id = "unknown", turtle = s.id, ok = false,
                              error = E.BAD_ARGS, detail = derr, state = state.telemetry(s) },
                    config.PROTOCOL)
      else
        local vmsg, verr = net.validate(msg)
        if vmsg == nil then
          rednet.send(sender, { v = 1, id = tostring(msg.id or "unknown"), turtle = s.id,
                                ok = false, error = verr, state = state.telemetry(s) },
                      config.PROTOCOL)
        else
          -- IDEMPOTENCY: replay a cached response for a repeated id.
          -- This is what guarantees a retried `forward` does not move twice.
          local cached = dedupe:get(vmsg.id)
          if cached then
            rednet.send(sender, cached, config.PROTOCOL)
          else
            if vmsg.action == "stop" then s.mode = "executing" end
            local response = state.dispatch(s, ctx, vmsg)
            dedupe:put(vmsg.id, response)
            rednet.send(sender, response, config.PROTOCOL)
            if vmsg.action == "stop" then
              s.halted = true
              s.mode = "halted"
            end
          end
        end
      end
    else
      -- Idle tick: heartbeat telemetry only. Sleeps, never spins.
      local now = os.epoch("utc")
      if now - lastHeartbeat >= config.HEARTBEAT_MS then
        lastHeartbeat = now
        if controllerId then
          rednet.send(controllerId,
            { v = 1, type = "telemetry", turtle = s.id, state = state.telemetry(s) },
            config.ANNOUNCE_PROTOCOL)
        end
      end
      s.fuel = state.fuelLevel()
      s.inventoryFreeSlots = state.inventoryFreeSlots()
      if not s.halted then
        if s.mode ~= "stuck" then s.mode = "idle" end
      end
    end
  end
end

return state
