-- harness.lua — simulates CC:Tweaked APIs + the dev bridge + a turtle,
-- then loads the real base-bridge.lua logic and drives one command through.
-- Purpose: prove the state machine works, not just that it parses.

local log = {}
local function L(s) log[#log+1] = s; print(s) end

-- ---------------------------------------------------------------- JSON
local function enc(v)
    local t = type(v)
    if t == "nil" then return "null"
    elseif t == "boolean" then return tostring(v)
    elseif t == "number" then return tostring(v)
    elseif t == "string" then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n','\\n') .. '"'
    elseif t == "table" then
        local isarr = #v > 0
        if isarr then
            local p = {}
            for i = 1, #v do p[i] = enc(v[i]) end
            return "[" .. table.concat(p, ",") .. "]"
        end
        local p = {}
        for k, val in pairs(v) do p[#p+1] = '"'..k..'":'..enc(val) end
        table.sort(p)
        return "{" .. table.concat(p, ",") .. "}"
    end
    return "null"
end
local function dec(s)
    local i = 1
    local function skip() while i <= #s and s:sub(i,i):match("[%s]") do i = i + 1 end end
    local parse
    parse = function()
        skip()
        local c = s:sub(i,i)
        if c == "{" then
            i = i + 1; local o = {}; skip()
            if s:sub(i,i) == "}" then i = i + 1; return o end
            while true do
                skip(); i = i + 1  -- opening quote
                local k = ""
                while s:sub(i,i) ~= '"' do k = k .. s:sub(i,i); i = i + 1 end
                i = i + 1; skip(); i = i + 1  -- colon
                o[k] = parse(); skip()
                local d = s:sub(i,i); i = i + 1
                if d == "}" then return o end
            end
        elseif c == "[" then
            i = i + 1; local a = {}; skip()
            if s:sub(i,i) == "]" then i = i + 1; return a end
            while true do
                a[#a+1] = parse(); skip()
                local d = s:sub(i,i); i = i + 1
                if d == "]" then return a end
            end
        elseif c == '"' then
            i = i + 1; local out = ""
            while true do
                local ch = s:sub(i,i)
                if ch == "\\" then
                    local n = s:sub(i+1,i+1)
                    out = out .. (n == "n" and "\n" or n)
                    i = i + 2
                elseif ch == '"' then i = i + 1; break
                else out = out .. ch; i = i + 1 end
            end
            return out
        elseif s:sub(i,i+4) == "true" then i = i + 4; return true
        elseif s:sub(i,i+5) == "false" then i = i + 5; return false
        elseif s:sub(i,i+4) == "null" then i = i + 4; return nil
        else
            local n = s:match("^%-?%d+%.?%d*", i)
            i = i + #n
            return tonumber(n)
        end
    end
    return parse()
end

-- ---------------------------------------------------------------- CC stubs
local files = { ["/bridge-token.txt"] = "test-token-abc" }
fs = {
    exists = function(p) return files[p] ~= nil end,
    open = function(p, m)
        if m == "r" then
            return { readAll = function() return files[p] or "" end, close = function() end }
        end
        return { write = function(_, s) files[p] = s end, close = function() end }
    end,
}
peripheral = { getType = function(side) return side == "back" and "modem" or nil end }
textutils = {
    serialiseJSON = enc, unserialiseJSON = dec, serializeJSON = enc, unserializeJSON = dec,
}
term_ = function() end

-- ---------------------------------------------------------------- rednet
local sent = {}
local pendingTurtle = nil
rednet = {
    open = function(side) L("[rednet] open on " .. side) end,
    send = function(id, msg, proto) sent[#sent+1] = { id = id, msg = msg, proto = proto } end,
    broadcast = function(msg, proto) sent[#sent+1] = { id = "ALL", msg = msg, proto = proto } end,
    receive = function(proto, timeout)
        -- simulate the turtle answering
        if pendingTurtle then
            local r = pendingTurtle; pendingTurtle = nil
            return 2, r
        end
        return nil, nil
    end,
}

-- ---------------------------------------------------------------- bridge sim
-- Emulates: handshake -> 101, register -> ack, then pushes one cmd update.
local bridgeScript = {
    { dir = "srv", payload = nil },                      -- expect register
    { dir = "cli", payload = enc({ type="ack", action="register", client_id="base-computer" }) },
    { dir = "cli", payload = enc({ type="update", client_id="base-computer",
                                   path = "cmd/mine.json",
                                   content = enc({ command = "status" }) }) },
    { dir = "cli", payload = nil },                       -- expect telemetry write
}

local queue = {}
for i, step in ipairs(bridgeScript) do queue[i] = step end
local qi = 0
local websocketURL = nil
local gotTelemetry = nil

local fakeWS = {
    send = function(data)
        local m = dec(data)
        if m.type == "register" then
            assert(m.token == "test-token-abc", "token mismatch: " .. tostring(m.token))
            assert(m.client_id == "base-computer", "client_id mismatch")
            L("[ws] -> register (token ok, client_id=" .. m.client_id .. ")")
        elseif m.type == "write" then
            gotTelemetry = dec(m.content)
            L("[ws] -> write " .. m.path .. " = " .. m.content)
        end
    end,
    receive = function(t)
        while true do
            qi = qi + 1
            local step = queue[qi]
            if not step then return nil end
            if step.payload ~= nil then return step.payload end
        end
    end,
    close = function() L("[ws] closed") end,
}

local pullQueue = {}
http = {
    websocket = function(url)
        websocketURL = url
        L("[http] websocket(" .. url .. ") -> async")
        pullQueue[#pullQueue+1] = { "http_success", url, fakeWS }
    end,
}
os.pullEvent = function()
    local e = table.remove(pullQueue, 1)
    if e then return unpack(e) end
    return "timer", 0
end

-- ---------------------------------------------------------------- driver
-- Load the real implementation, but stop before its main() by stripping the
-- final call: we drive the phases ourselves with a bounded serve().
local src = io.open("/root/.hermes/profiles/mai/cache/scratch/base-bridge.lua"):read("*a")
-- Replace the final main() call with a hook that captures the chunk's locals.
src = src:gsub("\nmain%(%)%s*$", "\n__T = { connect = connect, runCommand = runCommand, report = report, isActionable = isActionable }\n")
assert(src:find("__T = "), "could not inject test hook")

-- expose internals by wrapping the chunk
local env = setmetatable({}, { __index = _G })
env.fs, env.peripheral, env.textutils = fs, peripheral, textutils
env.rednet, env.http, env.os = rednet, http, os
env.print, env.printError, env.sleep = print, print, function() end
env.table, env.string, env.ipairs, env.pairs, env.type, env.pcall = table, string, ipairs, pairs, type, pcall
env.assert, env.error, env.tostring, env.tonumber, env.select = assert, error, tostring, tonumber, select
env._G = env

local chunk = assert(loadstring(src, "base-bridge"))
setfenv(chunk, env)
chunk()

-- register the turtle's canned answer
pendingTurtle = { type = "status", id = 2, message = "idle",
                  fuel = 812, usedSlots = 3, totalItems = 57 }

local function boundedCycle()
    local sock, cerr = env.__T.connect()
    if not sock then L("connect error: " .. tostring(cerr)); return false end
    L("[ok] connected + registered")
    -- feed exactly the update step, then telemetry step
    for _ = 1, 2 do
        local raw = sock.receive(30)
        if raw == nil then break end
        local msg = dec(raw)
        if msg.type == "update" then
            local cmd = dec(msg.content).command
            L("[bus] update cmd/" .. " -> command=" .. cmd)
            local result = env.__T.runCommand(cmd)
            L("[rednet] sent to turtle; response id=" .. tostring(result.id) ..
              " status=" .. tostring(result.status) .. " fuel=" .. tostring(result.fuel))
            env.__T.report(sock, result)
        end
    end
    return true
end

L("=== driving one full cycle ===")
assert(boundedCycle(), "cycle failed")
L("=== assertions ===")
assert(#sent == 1, "expected 1 rednet broadcast, got " .. #sent)
assert(sent[1].proto == "minerfleet", "protocol mismatch")
assert(sent[1].msg.command == "status", "command not relayed")
L("[assert] rednet broadcast: command=status proto=minerfleet  OK")
assert(gotTelemetry, "no telemetry written back")
assert(gotTelemetry.status == "idle", "telemetry status wrong")
assert(gotTelemetry.fuel == 812, "telemetry fuel wrong")
L("[assert] telemetry written back: " .. enc(gotTelemetry) .. "  OK")
L("=== ALL LOGIC ASSERTIONS PASSED ===")
