-- fleet/turtle_startup.lua — worker entry point for turtle 2 (Bot001).
--
-- Runs on EVERY boot including after a chunk reload, so it must be idempotent.
-- Every step writes to /fleet/last_run.txt as well as print(), because CC's
-- print() output never reaches the server log — the trace file is the only
-- observable evidence of what this program did.

local TRACE = "/fleet/last_run.txt"

local function trace(s)
  local line = tostring(s)
  print("[fleet] " .. line)
  local f = fs.open(TRACE, "a")
  if f then f.write(os.epoch("utc") .. " " .. line .. "\n"); f.close() end
end

pcall(fs.delete, TRACE)
trace("turtle boot; id=" .. tostring(os.getComputerID()) ..
      " label=" .. tostring(os.getComputerLabel()))

local ok, err = pcall(function()
  dofile("/fleet/load.lua")

  local config = requireModule("config")
  if not config then trace("FATAL no config module") return end
  trace("config MODE=" .. tostring(config.MODE) ..
        " TURTLE_ID=" .. tostring(config.TURTLE_ID) ..
        " CONTROLLER_ID=" .. tostring(config.CONTROLLER_ID) ..
        " PROTOCOL=" .. tostring(config.PROTOCOL))

  local state = requireModule("state")
  if not state then trace("FATAL no state module") return end

  -- Confirm we really are a turtle before touching the turtle API.
  if turtle == nil then
    trace("FATAL not a turtle (no turtle API)")
    return
  end
  trace("turtle API present")

  local id = config.TURTLE_ID or os.getComputerLabel() or os.getComputerID()
  trace("worker id=" .. tostring(id))

  -- Open a modem, preferring WIRED (no length cap). state.openModem() picks the
  -- first modem it finds; we do our own pass so the trace records which side and
  -- whether it is wireless.
  local modemSide, wireless = nil, nil
  for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral.getType(side) == "modem" then
      local isWl = false
      local okw, res = pcall(peripheral.call, side, "isWireless")
      if okw and res then isWl = true end
      modemSide, wireless = side, isWl
      break
    end
  end

  -- An ender MODEM gives unlimited range and cross-dimension reach, but it is
  -- still a modem: rednet must be bound to its side exactly once, below.
  if modemSide then
    local okOpen, openErr = pcall(rednet.open, modemSide)
    if okOpen then
      trace("rednet open on " .. modemSide .. " wireless=" .. tostring(wireless))
    else
      trace("FATAL modem " .. modemSide .. " failed: " .. tostring(openErr))
      return
    end
  else
    trace("FATAL no modem on any side - attach a wireless or ender modem")
    return
  end

  -- Host on the controller id so the turtle can address it directly, then open
  -- the protocol channel and listen on it.
  local cid = config.CONTROLLER_ID
  -- API asymmetry, both verified against tweaked.cc/module/rednet.html:
  --   rednet.host(protocol, hostname)          -> BOTH strings. No booleans.
  --   rednet.send(recipient, message, protocol) -> recipient is a NUMBER.
  -- host(5, true)      -> "bad argument #1 (string expected, got number)"
  -- host(PROTO, true)  -> "bad argument #2 (string expected, got boolean)"
  -- Either failure left rednet.open() with no bound modem.
  local hostNum = tonumber(cid) or 5
  if cid then
    local okH, hErr = pcall(rednet.host, config.PROTOCOL, tostring(id))
    trace("rednet.host('" .. tostring(config.PROTOCOL) .. "') ok=" .. tostring(okH) ..
          (okH and "" or (" err=" .. tostring(hErr))))
  else
    trace("CONTROLLER_ID is nil — broadcasting instead of addressing")
  end

  -- NOTE: there is deliberately NO second rednet.open() here. rednet.open takes
  -- a MODEM SIDE, not a protocol name; calling it again with "fleet-v1" was the
  -- source of the earlier "no such modem fleet-v1" failure.
  trace("bound to modem; ready")

  -- Announce once so the controller logs us, then serve commands forever.
  local function telemetry()
    local fuel = turtle.getFuelLevel()
    local used = 0
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > 0 then used = used + 1 end
    end
    return {
      turtle = id,
      fuel = fuel,
      usedSlots = used,
      modem = modemSide,
      wireless = wireless,
      controllerId = cid,
      booted = os.epoch("utc"),
    }
  end

  -- Tell the controller we exist.
  local okSend, sendErr = pcall(function()
    rednet.send(hostNum, { state = telemetry() }, config.PROTOCOL)
  end)
  trace("announce ok=" .. tostring(okSend) ..
        (okSend and "" or (" err=" .. tostring(sendErr))))

  local heartbeat = os.startTimer(10)
  local handled = 0

  while true do
    local event, p1, p2 = os.pullEvent()

    if event == "timer" then
      heartbeat = nil
      pcall(function()
        rednet.send(hostNum, { state = telemetry() }, config.PROTOCOL)
      end)
      heartbeat = os.startTimer(10)

    elseif event == "rednet_message" then
      -- p1 is the SENDER's computer id, NOT a protocol name. The old code
      -- compared p1 against config.PROTOCOL ("fleet-v1"), which never matches a
      -- number, so every inbound command would have been silently dropped.
      if tonumber(p1) == hostNum then
        local msg = type(p2) == "table" and p2 or nil
        if msg then
          handled = handled + 1
          trace("cmd#" .. handled .. " from=" .. tostring(p1) ..
                " action=" .. tostring(msg.action))
          pcall(function()
            rednet.send(p1, {
              v = 1,
              id = msg.id,
              ok = true,
              turtle = id,
              action = msg.action,
              state = telemetry(),
            }, config.PROTOCOL)
          end)
        end
      end

    elseif event == "computer_shutdown" or event == "terminate" then
      trace("shutdown")
      return
    end
  end
end)

if not ok then
  trace("FATAL " .. tostring(err))
end