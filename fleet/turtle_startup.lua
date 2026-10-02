-- fleet/turtle_startup.lua
-- Install as /startup.lua ON THE TURTLE.
-- Runs on EVERY boot, including after a chunk reload, so it must be idempotent.

local ok, err = pcall(function()
  local config = require("fleet.config")
  local state  = require("fleet.state")

  local isTurtle, terr = state.requireTurtle()
  if not isTurtle then
    print("[fleet] not a turtle: " .. tostring(terr))
    return
  end

  local s = state.new()
  print("[fleet] id = " .. s.id)

  local side, merr = state.openModem()
  if not side then
    print("[fleet] no modem found: " .. tostring(merr))
    return
  end
  print("[fleet] modem on " .. side .. "; listening on '" .. config.PROTOCOL .. "'")

  -- Announce, then listen forever.
  state.announce(s, config.CONTROLLER_ID)
  state.run(s)

  print("[fleet] halted.")
end)

if not ok then
  print("[fleet] fatal: " .. tostring(err))
end
