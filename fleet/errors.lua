-- fleet/errors.lua — the closed error taxonomy. Keep closed: it makes
-- lastError comparable across turtles and lets the fleet manager classify
-- "stuck" mechanically instead of by string matching.

return {
  MOVEMENT_OBSTRUCTED = "movement_obstructed",
  UNBREAKABLE_BLOCK   = "unbreakable_block",
  OUT_OF_FUEL         = "out_of_fuel",
  INVENTORY_FULL      = "inventory_full",
  NOTHING_TO_DIG      = "nothing_to_dig",
  NOTHING_TO_REFUEL   = "nothing_to_refuel",
  NOTHING_TO_INSPECT  = "nothing_to_inspect",
  UNSUPPORTED_ACTION  = "unsupported_action",
  BAD_ARGS            = "bad_args",
  TURTLE_API_MISSING  = "turtle_api_missing",
  INTERNAL_ERROR      = "internal_error",
  QUEUE_FULL          = "queue_full",
  TIMEOUT             = "timeout",
  HALTED              = "halted",
}
