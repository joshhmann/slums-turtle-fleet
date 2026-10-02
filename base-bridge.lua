-- base-bridge.lua — Slums MC "base computer" agent bridge
--
--   agent / WebUI
--        |  HTTP/WS
--   Base Computer  (this file: non-turtle program, runs on computer id 4)
--        |  rednet ("minerfleet")
--      T1 T2 T3 ...
--
-- Install on the BASE COMPUTER as startup.lua.
--
-- Inbound  : the bridge's watch() loop pushes {"type":"update",path,content}
--            to every registered websocket client whenever a file under its
--            root changes. Files under cmd/ are commands.
-- Outbound : telemetry is written back with {"type":"write",...}.
--
-- Channel design: http.websocket returns asynchronously via http_success /
-- http_failure pull events, so a receive loop cannot hold the socket directly
-- across a rednet.receive. Instead the socket is published into a global
-- channel that each phase of the state machine opens and closes.

local BRIDGE_HOST = "192.168.0.128"   -- NOT localhost: that is the MC container
local BRIDGE_PORT = 8765
local CLIENT_ID   = "base-computer"   -- [A-Za-z0-9_.-]{1,64}, must be unique
local TOKEN_FILE  = "/bridge-token.txt"

local PROTOCOL       = "minerfleet"
local CMD_PREFIX     = "cmd/"
local TELEMETRY_PATH = "telemetry/last.json"
local TURTLE_TARGET  = nil            -- nil = broadcast to the fleet
local RESPONSE_WAIT  = 4

-- ---------------------------------------------------------------- token
local function loadToken()
    if not fs.exists(TOKEN_FILE) then
        error("missing " .. TOKEN_FILE .. " — create it with: edit " .. TOKEN_FILE, 0)
    end
    local f = fs.open(TOKEN_FILE, "r")
    local t = f.readAll()
    f.close()
    return (t:gsub("%s+$", ""))
end

-- ---------------------------------------------------------------- modem
local function openRednet()
    for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            return side
        end
    end
    error("No modem attached — rednet needs a wireless or wired modem", 0)
end

-- ---------------------------------------------------------------- socket
-- Returns a connected+registered socket, or nil+err. Never yields for rednet.
local function connect()
    local url = ("ws://%s:%d/"):format(BRIDGE_HOST, BRIDGE_PORT)
    http.websocket(url)
    local event, a, b = os.pullEvent()
    if event == "http_failure" then
        return nil, "connect failed: " .. tostring(a)
    elseif event ~= "http_success" or a ~= url then
        return nil, "unexpected event " .. tostring(event)
    end

    local ws = b
    local ok = pcall(function()
        ws.send(textutils.serialiseJSON({
            type = "register", token = loadToken(), client_id = CLIENT_ID,
        }))
    end)
    if not ok then ws.close(); return nil, "register send failed" end

    local reply = ws.receive(8)
    if not reply then ws.close(); return nil, "no register response" end

    local okd, ack = pcall(textutils.unserialiseJSON, reply)
    if not okd and type(textutils.unserializeJSON) == "function" then
        okd, ack = pcall(textutils.unserializeJSON, reply)
    end
    if not okd or type(ack) ~= "table" or ack.type ~= "ack" then
        ws.close()
        return nil, "register rejected: " .. tostring(reply)
    end
    return ws
end

-- ---------------------------------------------------------------- command
local function runCommand(command)
    if TURTLE_TARGET == nil then
        rednet.broadcast({ command = command }, PROTOCOL)
    else
        rednet.send(TURTLE_TARGET, { command = command }, PROTOCOL)
    end

    local sender, response = rednet.receive(PROTOCOL, RESPONSE_WAIT)
    if type(response) ~= "table" then
        return { command = command, id = sender, error = "no turtle response" }
    end
    return {
        command = command,
        id      = response.id,
        status  = response.message,
        fuel    = response.fuel,
        slots   = response.usedSlots,
        items   = response.totalItems,
    }
end

-- LOOP GUARD: the bridge pushes an "update" for EVERY changed file under its
-- root, including the telemetry we write back. Without the cmd/ check the
-- computer would receive its own telemetry and relay it as a command forever.
local function isActionable(msg)
    return type(msg.path) == "string"
       and msg.path:sub(1, #CMD_PREFIX) == CMD_PREFIX
       and type(msg.content) == "string"
end

local function report(ws, result)
    pcall(function()
        ws.send(textutils.serialiseJSON({
            type = "write", path = TELEMETRY_PATH,
            content = textutils.serialiseJSON(result),
        }))
    end)
end

-- ---------------------------------------------------------------- phases
local function serve(ws)
    print("base-bridge: registered with " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT)
    while true do
        local raw = ws.receive(30)
        if raw == nil then
            -- idle timeout; ping keeps the connection alive, keep waiting
        elseif raw == false then
            return "closed"
        else
            local ok, msg = pcall(textutils.unserialiseJSON, raw)
            if ok and type(msg) == "table" and msg.type == "update" and isActionable(msg) then
                local cmd = msg.content
                local okp, payload = pcall(textutils.unserialiseJSON, msg.content)
                if okp and type(payload) == "table" and payload.command then
                    cmd = payload.command
                end
                report(ws, runCommand(cmd))
            end
        end
    end
end

local function main()
    local side = openRednet()
    print("base-bridge: rednet open on " .. side)
    print("base-bridge: target = " ..
        (TURTLE_TARGET and tostring(TURTLE_TARGET) or "broadcast"))

    while true do
        local ws, err = connect()
        if not ws then
            printError("base-bridge: " .. tostring(err) .. " — retry in 10s")
            sleep(10)
        else
            serve(ws)
            pcall(function() ws.close() end)
            print("base-bridge: socket closed — reconnecting")
            sleep(5)
        end
    end
end

main()
