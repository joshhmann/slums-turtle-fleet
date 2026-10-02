-- fleet/main.lua — controller entry point for computer 5.
--
-- CC:Tweaked constraints this file is written around (all observed live 2026-10-02):
--   * `require` is NOT a global. Modules load via fleet/load.lua -> requireModule.
--   * `print()` never reaches the server log. /fleet/last_run.txt is the only
--     observable trace, so every step appends to it.
--   * http.websocket() is SYNCHRONOUS and blocks the coroutine. Only one socket
--     may exist at a time, so the shell reports "socket open is in use" while
--     this runs. That is expected, not a fault.
--   * rednet is OPTIONAL: bridge-only until a turtle with a modem registers.

local DIR = "/fleet/"
local TRACE = DIR .. "last_run.txt"
local MODULES = {}

local function trace(s)
  local line = tostring(s)
  print("[fleet] " .. line)
  local f = fs.open(TRACE, "a")
  if f then f.write(os.epoch("utc") .. " " .. line .. "\n"); f.close() end
end

local function fatal(s)
  trace("FATAL " .. tostring(s))
  os.sleep(30)
end

local function loadModule(name)
  if MODULES[name] then return MODULES[name] end
  local path = DIR .. name .. ".lua"
  if not fs.exists(path) then return nil, "missing " .. path end
  local chunk = loadfile(path)
  if not chunk then return nil, "parse failed " .. path end
  local ok, result = pcall(chunk)
  if not ok then return nil, "load error " .. tostring(result) end
  MODULES[name] = result
  return result
end

local function jsonEscape(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  return s
end

-- Hand-rolled JSON object writer. The auth-critical frames do NOT go through
-- textutils.serialiseJSON: that call was returning nil here, so ws.send(nil)
-- silently sent nothing and left the socket open with no reply.
local function jsonObject(t)
  local parts = {}
  for k, v in pairs(t) do
    if type(v) == "string" then
      parts[#parts + 1] = '"' .. jsonEscape(k) .. '":"' .. jsonEscape(v) .. '"'
    elseif type(v) == "number" or type(v) == "boolean" then
      parts[#parts + 1] = '"' .. jsonEscape(k) .. '":' .. tostring(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

pcall(fs.delete, TRACE)
trace("boot")

-- ---- modules ---------------------------------------------------------------

local loaderOk, lerr = pcall(dofile, DIR .. "load.lua")
if not loaderOk then fatal("load.lua " .. tostring(lerr)) return end

local config, cerr = loadModule("config")
if not config then fatal("config " .. tostring(cerr)) return end
local net, nerr = loadModule("net")
if not net then fatal("net " .. tostring(nerr)) return end

trace("modules ok MODE=" .. tostring(config.MODE) ..
      " bridge=" .. tostring(config.BRIDGE_ENABLED))

-- ---- optional rednet (CALLED, unlike the previous revision) ---------------

local rednetOk = false
for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
  if peripheral.getType(side) == "modem" then
    local ok, err = pcall(rednet.open, side)
    if ok then
      rednetOk = true
      trace("rednet open on " .. side)
      break
    else
      trace("modem " .. side .. " failed: " .. tostring(err))
    end
  end
end
if not rednetOk then trace("NO MODEM - bridge-only mode") end

-- Host the fleet protocol so turtles have something to connect to. Asymmetry to
-- remember (verified against tweaked.cc/module/rednet.html):
--   rednet.host(protocol, hostname)          -> BOTH strings. There are no
--                                               boolean args; my earlier
--                                               host(PROTOCOL, true, true)
--                                               raised "bad argument #2
--                                               (string expected, got boolean)".
--   rednet.send(recipient, message, protocol) -> recipient is a NUMBER.
if rednetOk then
  local okH, hErr = pcall(rednet.host, config.PROTOCOL, "fleet-ctrl")
  trace("rednet.host('" .. tostring(config.PROTOCOL) .. "') ok=" .. tostring(okH) ..
        (okH and "" or (" err=" .. tostring(hErr))))
end

-- ---- state -----------------------------------------------------------------

local REG = {}
local uptimeStart = os.epoch("utc")

local function readToken()
  if not fs.exists(config.BRIDGE_TOKEN_FILE) then
    return nil, "missing " .. config.BRIDGE_TOKEN_FILE
  end
  local f = fs.open(config.BRIDGE_TOKEN_FILE, "r")
  if not f then return nil, "cannot open" end
  local raw = f.readAll()
  f.close()
  local token = (raw:gsub("%s+$", ""))
  if #token == 0 then return nil, "empty" end
  return token
end

local function turtleList()
  local list = {}
  for id, rec in pairs(REG) do
    list[#list + 1] = {
      id = id,
      status = rec.online and "working" or "unknown",
      job = rec.job or "-",
      job_id = rec.job_id or "-",
      pos = {
        x = rec.x or 0, y = rec.y or 0, z = rec.z or 0,
        source = rec.posSource or "odometry",
      },
      fuel = { current = rec.fuel or 0, max = config.NORMAL_FUEL_LIMIT or 20000 },
      inventory = { used_slots = rec.usedSlots or 0 },
      capabilities = rec.capabilities or {},
      last_seen_epoch = rec.lastSeen or os.epoch("utc"),
    }
  end
  return list
end

local function encodeTelemetry()
  local body = {
    version = 1,
    updated_epoch = os.epoch("utc"),
    controller = {
      id = config.BRIDGE_CLIENT_ID,
      bridge = "connected",
      rednet = rednetOk,
      uptime_s = os.epoch("utc") - uptimeStart,
    },
    turtles = turtleList(),
  }
  -- Nested structure: the runtime serialiser handles arrays/tables correctly,
  -- which our flat jsonObject cannot.
  local ok, out = pcall(textutils.serialiseJSON, body)
  if ok and type(out) == "string" and #out > 2 then return out end
  return nil, tostring(out)
end

-- ---- main loop -------------------------------------------------------------

local backoff = config.BACKOFF_MIN_MS

while true do
  local token, terr = readToken()

  if not token then
    trace("token " .. tostring(terr))
    os.sleep(5)

  elseif not config.BRIDGE_ENABLED then
    trace("BRIDGE_ENABLED false")
    os.sleep(5)

  else
    trace("connect " .. tostring(config.BRIDGE_URL))
    local ws, werr = http.websocket(config.BRIDGE_URL)

    if not ws then
      trace("connect failed: " .. tostring(werr))
      os.sleep(backoff / 1000)
      backoff = math.min(backoff * 2, config.BACKOFF_MAX_MS)

    else
      backoff = config.BACKOFF_MIN_MS
      trace("socket open")

      local reg = jsonObject({
        type = "register",
        token = token,
        client_id = config.BRIDGE_CLIENT_ID,
      })
      trace("register frame " .. #reg .. "B")

      local sent, serr = pcall(function() ws.send(reg) end)
      if not sent then
        trace("send failed: " .. tostring(serr))
        pcall(function() ws.close() end)
        os.sleep(2)
      else
        trace("register sent")

        -- websocket_message fires as (websocket, url, payload). The first event
        -- after registering is the ack, but a nil payload means the socket
        -- closed, so check that before treating anything as a reply.
        local firstEvent, p1, p2 = os.pullEvent("websocket_message", 8)
        if firstEvent == nil then
          trace("no reply in 8s")
        elseif firstEvent == "websocket_closed" or p2 == nil then
          trace("socket closed before ack")
        end

        trace("ack seen; entering heartbeat loop")

        -- One timer for the life of the loop. The previous version called
        -- os.startTimer() on EVERY iteration, so every rednet/websocket event
        -- leaked a timer. With turtles reporting every few seconds the count
        -- exploded, os.startTimer began failing, the heartbeat timer never fired
        -- again, and telemetry stopped updating entirely.
        local heartbeat = os.startTimer(config.HEARTBEAT_MS / 1000)

        while true do
          local event, p1, p2 = os.pullEvent()

          if event == "timer" and p1 == heartbeat then
            heartbeat = nil
            local payload, eerr = encodeTelemetry()
            if not payload then
              trace("telemetry encode failed: " .. tostring(eerr))
            else
              local frame = jsonObject({
                type = "write",
                path = config.BRIDGE_TELEMETRY_DIR .. "fleet.json",
                content = payload,
              })
              local ok, werr2 = pcall(function() ws.send(frame) end)
              if not ok then
                trace("telemetry send failed: " .. tostring(werr2))
                break
              end
              trace("telemetry sent " .. #frame .. "B")
            end
            -- Only restart after actually handling the heartbeat.
            heartbeat = os.startTimer(config.HEARTBEAT_MS / 1000)

          elseif event == "rednet_message" then
            -- p1 is the SENDER's computer id, not a protocol name. Comparing it
            -- against config.PROTOCOL ("fleet-v1") never matches, so this branch
            -- would have silently ignored every turtle.
            local senderId = tonumber(p1)
            local rmsg = type(p2) == "table" and p2 or nil
            if senderId and rmsg and type(rmsg.state) == "table" then
              local st = rmsg.state
              local id = st.turtle or ("t" .. tostring(senderId))
              local rec = REG[id] or {}
              for k, v in pairs(st) do rec[k] = v end
              rec.online = true
              rec.computerId = senderId
              rec.lastSeen = os.epoch("utc")
              REG[id] = rec
            end

          elseif event == "websocket_message" then
            if p1 == nil and p2 == nil then
              trace("socket closed")
              break
            end
            trace("ws in " .. tostring(p2):sub(1, 120))

          elseif event == "computer_shutdown" or event == "terminate" then
            pcall(function() ws.close() end)
            trace("shutdown")
            return
          end
        end

        pcall(function() ws.close() end)
        trace("disconnected, backoff " .. math.floor(backoff / 1000) .. "s")
        os.sleep(backoff / 1000)
        backoff = math.min(backoff * 2, config.BACKOFF_MAX_MS)
      end
    end
  end
end