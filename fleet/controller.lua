-- fleet/controller.lua — the Fleet Controller.
-- Owns: registry, scheduling, state, retries, idempotency, and (optionally)
-- the WebSocket bridge to the external control plane.
-- Two coroutines via parallel.waitForAny: rednet loop + ws loop.
-- A single loop CANNOT do both — a coroutine blocked in rednet.receive
-- does not service websocket events (DESIGN §3.2).

local config = requireModule("config")
local net    = requireModule("net")
local E      = requireModule("errors")

local controller = {}

function controller.new()
  return {
    registry = {},          -- id -> turtle record
    queue = {},             -- bounded outbound queue
    bootEpoch = os.epoch("utc"),
    stopRequested = false,
  }
end

-- ---- registry -----------------------------------------------------------

-- `online` is DERIVED from recency, never stored as truth: a turtle that
-- unloads its chunk simply stops talking, and there is no disconnect event.
function controller.touch(c, telemetry)
  if type(telemetry) ~= "table" or type(telemetry.turtle) ~= "string" then return end
  local id = telemetry.turtle
  local rec = c.registry[id] or { id = id, history = {} }
  rec.last_seen = os.epoch("utc")
  rec.state = telemetry.state
  rec.fuel = telemetry.fuel
  rec.inventoryFreeSlots = telemetry.inventoryFreeSlots
  rec.lastCommand = telemetry.lastCommand
  rec.lastError = telemetry.lastError
  rec.pos = telemetry.pos
  rec.facing = telemetry.facing
  rec.halted = telemetry.halted
  rec.online = true
  c.registry[id] = rec
  return rec
end

function controller.sweep(c)
  local now = os.epoch("utc")
  for _, rec in pairs(c.registry) do
    rec.online = (rec.last_seen ~= nil) and (now - rec.last_seen < config.OFFLINE_MS)
  end
end

function controller.onlineTurtles(c)
  local list, n = {}, 0
  for _, rec in pairs(c.registry) do
    if rec.online then n = n + 1; list[n] = rec end
  end
  return list
end

-- ---- queue --------------------------------------------------------------

function controller.enqueue(c, turtleId, action, args)
  if c.stopRequested then return nil, E.HALTED end
  if #c.queue >= config.QUEUE_MAX then return nil, E.QUEUE_FULL end
  local id = net.newIdMinter(turtleId)
  -- NOTE: minter is per-call here; keep one minter on the controller in real use.
  local msg = { v = 1, id = id(), action = action, args = args or {} }
  c.queue[#c.queue + 1] = { turtle = turtleId, msg = msg, attempts = 0, sent_at = nil }
  return msg.id
end

-- ---- command send with idempotent retry ---------------------------------

-- Re-sends the SAME id on retry. The turtle replays its cached response
-- instead of re-executing, so a lost reply never causes a double move.
function controller.sendWait(c, turtleId, action, args, opts)
  opts = opts or {}
  local rec = c.registry[turtleId]
  if not rec then return nil, "unknown_turtle" end
  local targetId = rec.computerId
  if not targetId then return nil, "unknown_computer_id" end

  local minter = opts.minter
  local id = minter and minter() or ("%s-%d-001"):format(turtleId, os.epoch("utc"))
  local msg = { v = 1, id = id, action = action, args = args or {},
                deadline_ms = opts.deadline_ms or config.COMMAND_TIMEOUT_MS }

  for attempt = 1, config.MAX_ATTEMPTS do
    rednet.send(targetId, msg, config.PROTOCOL)
    local sender, raw = rednet.receive(config.PROTOCOL, config.COMMAND_TIMEOUT_MS / 1000)
    if raw then
      local resp = net.decode(raw)
      if type(resp) == "table" and resp.id == id then
        controller.touch(c, resp.state)
        return resp
      end
      -- A response for a different id: not ours, keep waiting this attempt.
    end
    if attempt < config.MAX_ATTEMPTS then
      local backoff = ({ 1, 3, 8 })[attempt] or 8
      os.sleep(backoff)
    end
  end
  rec.online = false
  return nil, E.TIMEOUT
end

-- ---- display ------------------------------------------------------------

function controller.printFleet(c)
  controller.sweep(c)
  print(("Fleet @ %s"):format(os.date("%H:%M:%S")))
  local any = false
  for id, rec in pairs(c.registry) do
    any = true
    print(("  %-6s %-10s fuel=%-5s inv=%-3s %s"):format(
      id,
      rec.online and (rec.state or "?") or "OFFLINE",
      tostring(rec.fuel or "-"),
      tostring(rec.inventoryFreeSlots or "-"),
      rec.online and "" or ("last seen " .. tostring(rec.last_seen))
    ))
  end
  if not any then print("  (no turtles seen yet)") end
end

-- ---- bridge (controller only) -------------------------------------------

-- http.websocket is SYNCHRONOUS. Do not wait for http_success/http_failure.
local function connectBridge()
  local token
  local f = fs.open(config.BRIDGE_TOKEN_FILE, "r")
  if f then token = f.readAll():gsub("%s+$", ""); f.close() end
  if not token or #token == 0 then return nil, "no_token" end

  local ws, err = http.websocket(config.BRIDGE_URL)
  if not ws then return nil, err or "ws_failed" end

  ws.send(net.encode({ type = "register", token = token, client_id = config.BRIDGE_CLIENT_ID }))
  return ws
end

-- ---- main ---------------------------------------------------------------

function controller.run(c)
  -- rednet loop: registry, heartbeats, and (optionally) bridged commands.
  local function rednetLoop()
    while true do
      local sender, raw = rednet.receive(config.ANNOUNCE_PROTOCOL, 1)
      if raw then
        local msg = net.decode(raw)
        if type(msg) == "table" and msg.state then
          local rec = controller.touch(c, msg.state)
          if rec then rec.computerId = sender end
        end
      end
      -- poll the stop protocol so a halt cannot be blocked
      local _, stopRaw = rednet.receive(config.STOP_PROTOCOL, 0)
      if stopRaw then
        local sm = net.decode(stopRaw)
        if type(sm) == "table" and sm.type == "stop" then
          c.stopRequested = true
          c.queue = {}
          for id, rec in pairs(c.registry) do
            rec.halted = true
            if rec.computerId then
              rednet.send(rec.computerId, net.encode(sm), config.STOP_PROTOCOL)
            end
          end
        end
      end
    end
  end

  -- ws loop: only if enabled. Owns the socket exclusively.
  local function wsLoop()
    if not config.BRIDGE_ENABLED then return end
    local backoff = config.BACKOFF_MIN_MS
    while true do
      local ws, err = connectBridge()
      if not ws then
        print("[bridge] connect failed: " .. tostring(err))
        os.sleep(backoff / 1000)
        backoff = math.min(backoff * 2, config.BACKOFF_MAX_MS)
      else
        backoff = config.BACKOFF_MIN_MS
        while true do
          local _, url, payload = os.pullEvent("websocket_message")
          if url == nil and payload == nil then break end   -- closed
          if type(payload) == "string" then
            local msg = net.decode(payload)
            -- Only relay commands, and only under our prefix: the bridge's
            -- watch() pushes EVERY changed file, including our own telemetry.
            if type(msg) == "table" and msg.action and msg.turtle then
              local rec = c.registry[msg.turtle]
              if rec and rec.computerId then
                rednet.send(rec.computerId, msg, config.PROTOCOL)
              end
            end
          end
        end
        print("[bridge] disconnected; backing off")
        os.sleep(backoff / 1000)
      end
    end
  end

  parallel.waitForAny(rednetLoop, wsLoop)
end

return controller
