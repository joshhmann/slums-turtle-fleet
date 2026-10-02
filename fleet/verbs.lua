-- fleet/verbs.lua — the action allowlist. THE security boundary.
-- No arbitrary code execution, ever: the network can only select from this
-- table. Anything not here is refused with unsupported_action.

local E = requireModule("errors")

local verbs = {}

-- action name -> { fn = function(ctx, args) -> ok, result, err, detail }
-- ctx provides: turtle api, config, state (for latched conditions)

local function fuelLevel()
  local f = turtle.getFuelLevel()
  -- getFuelLevel() returns the STRING "unlimited" when fuel is disabled.
  if type(f) == "string" then return nil, f end
  return f
end

local function guardFuel(ctx)
  local f, raw = fuelLevel()
  if f == nil and raw == "unlimited" then return true end
  if not f or f <= 0 then
    ctx.state.out_of_fuel = true
    return false
  end
  return true
end

local function guardInventory(ctx, need)
  ctx.state.inventoryFreeSlots = ctx.inventoryFreeSlots()
  if ctx.state.inventoryFreeSlots < (need or 1) then
    ctx.state.inventory_full = true
    return false
  end
  return true
end

-- ---- movement -----------------------------------------------------------

-- Dead-reckoned offsets. `pos` starts all-nil because CC:Tweaked exposes no
-- world coordinates (DESIGN §6.3), and a nil coordinate must NEVER be
-- arithmetic'd: doing so throws AFTER the turtle has already moved, which
-- turns a successful move into a reported internal_error. That is precisely
-- the failure mode that invites a controller retry and a double move.
-- Instead we set the axis to `nil` (unknown) and rely on absolute
-- dead-reckoning offsets that survive an unknown origin.
local function bump(ctx, axis, delta)
  local pos = ctx.state.pos
  if pos == nil then return end
  pos[axis] = (pos[axis] or 0) + delta
end

verbs.forward = { moves = true, fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  local ok, why = turtle.forward()
  if not ok then return false, E.MOVEMENT_OBSTRUCTED, why end
  bump(ctx, "z", -1)
  return true, {}
end }

verbs.back = { moves = true, fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  local ok, why = turtle.back()
  if not ok then return false, E.MOVEMENT_OBSTRUCTED, why end
  bump(ctx, "z", 1)
  return true, {}
end }

verbs.up = { moves = true, fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  local ok, why = turtle.up()
  if not ok then return false, E.MOVEMENT_OBSTRUCTED, why end
  bump(ctx, "y", 1)
  return true, {}
end }

verbs.down = { moves = true, fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  local ok, why = turtle.down()
  if not ok then return false, E.MOVEMENT_OBSTRUCTED, why end
  bump(ctx, "y", -1)
  return true, {}
end }

verbs.turn_left = { fn = function(ctx)
  turtle.turnLeft()
  ctx.state.facing = (ctx.state.facing + 3) % 4
  return true, { facing = ctx.state.facing }
end }

verbs.turn_right = { fn = function(ctx)
  turtle.turnRight()
  ctx.state.facing = (ctx.state.facing + 1) % 4
  return true, { facing = ctx.state.facing }
end }

-- ---- digging ------------------------------------------------------------

verbs.dig = { fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  if not guardInventory(ctx) then return false, E.INVENTORY_FULL end
  local present, data = turtle.inspect()
  if not present then return false, E.NOTHING_TO_DIG end
  local ok, why = turtle.dig()
  if not ok then return false, E.UNBREAKABLE_BLOCK, (data and data.name) or why end
  return true, { dug = data and data.name }
end }

verbs.dig_up = { fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  if not guardInventory(ctx) then return false, E.INVENTORY_FULL end
  local present, data = turtle.inspectUp()
  if not present then return false, E.NOTHING_TO_DIG end
  local ok, why = turtle.digUp()
  if not ok then return false, E.UNBREAKABLE_BLOCK, (data and data.name) or why end
  return true, { dug = data and data.name }
end }

verbs.dig_down = { fn = function(ctx)
  if not guardFuel(ctx) then return false, E.OUT_OF_FUEL end
  if not guardInventory(ctx) then return false, E.INVENTORY_FULL end
  local present, data = turtle.inspectDown()
  if not present then return false, E.NOTHING_TO_DIG end
  local ok, why = turtle.digDown()
  if not ok then return false, E.UNBREAKABLE_BLOCK, (data and data.name) or why end
  return true, { dug = data and data.name }
end }

-- ---- inspection ---------------------------------------------------------

local function inspectWith(fn, err)
  return function(ctx)
    local present, data = fn()
    if not present then return false, err end
    return true, { block = data and data.name, state = data and data.state }
  end
end

verbs.inspect      = { fn = inspectWith(turtle.inspect,      E.NOTHING_TO_INSPECT) }
verbs.inspect_up   = { fn = inspectWith(turtle.inspectUp,    E.NOTHING_TO_INSPECT) }
verbs.inspect_down = { fn = inspectWith(turtle.inspectDown,  E.NOTHING_TO_INSPECT) }

-- ---- reporting ----------------------------------------------------------

verbs.status = { fn = function(ctx)
  return true, { state = ctx.telemetry(ctx) }
end }

verbs.fuel = { fn = function(ctx)
  local f, raw = fuelLevel()
  return true, { fuel = (f == nil and raw or f) }
end }

verbs.inventory = { fn = function(ctx)
  local items, used, total = {}, 0, 0
  for slot = 1, 16 do
    local n = turtle.getItemCount(slot)
    if n > 0 then
      used = used + 1
      total = total + n
      items[#items + 1] = { slot = slot, name = turtle.getItemDetail(slot) and turtle.getItemDetail(slot).name or "?", count = n }
    end
  end
  ctx.state.inventoryFreeSlots = 16 - used
  return true, { items = items, usedSlots = used, totalItems = total, freeSlots = 16 - used }
end }

-- ---- refuel -------------------------------------------------------------

verbs.refuel = { fn = function(ctx)
  local args = ctx.args or {}
  local slot = tonumber(args.slot)
  local ok, err
  if slot then
    ok, err = turtle.refuel(slot)
  else
    -- refuel from every slot that holds fuel
    ok = false
    for s = 1, 16 do
      if turtle.refuel(s) then ok = true end
    end
  end
  if not ok then return false, E.NOTHING_TO_REFUEL, err end
  local f, raw = fuelLevel()
  ctx.state.out_of_fuel = false
  return true, { fuel = (f == nil and raw or f) }
end }

-- ---- control ------------------------------------------------------------

-- `stop` is handled by the dispatcher (it latches state), but is listed here
-- so it appears in the allowlist and is accepted over the wire.
verbs.stop = { fn = function(ctx)
  ctx.state.halted = true
  return true, { halted = true }
end }

verbs.resume = { fn = function(ctx)
  ctx.state.halted = false
  ctx.state.stuck_count = 0
  return true, { halted = false }
end }

return verbs
