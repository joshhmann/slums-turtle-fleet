-- fleet/config.lua — single source of truth for both turtle and controller
-- Copy this file to each machine and edit MODE. Never type tokens in-game.

local config = {}

-- "turtle" | "controller"
config.MODE = "turtle"

-- Turtle identity. Set TURTLE_ID to match the machine's CC label.
config.TURTLE_ID = nil            -- e.g. "T01"; if nil, falls back to os.getComputerLabel()

-- Controller identity (the computer id turtles talk to). nil = broadcast.
config.CONTROLLER_ID = nil        -- e.g. 4

config.PROTOCOL = "fleet-v1"      -- rednet protocol for command traffic
config.ANNOUNCE_PROTOCOL = "fleet-announce"
config.STOP_PROTOCOL = "fleet-stop"

-- Timings (ms). Keep generous: computer_threads=1, max_main_computer_time=5ms.
config.HEARTBEAT_MS = 15000       -- idle telemetry
config.COMMAND_TIMEOUT_MS = 8000  -- turtle-side rednet.receive timeout
config.MAX_ATTEMPTS = 3           -- controller retries per command
config.DEDUPE_SIZE = 32           -- turtle idempotency ring buffer
config.QUEUE_MAX = 32             -- controller outbound queue depth
config.OFFLINE_MS = 45000         -- controller: last_seen older than this => offline

-- WebSocket bridge (controller only). Token is read from a FILE, never inlined.
-- VERIFIED 2026-10-01: http.websocket() is SYNCHRONOUS and blocks the coroutine.
-- Only websocketAsync fires websocket_success/websocket_failure. Anything that
-- blocks here will freeze the computer and starve turtle dispatch.
config.BRIDGE_ENABLED = false
config.BRIDGE_URL = "ws://192.168.0.128:8765/"
config.BRIDGE_TOKEN_FILE = "/bridge-token.txt"
config.BRIDGE_CLIENT_ID = "base-computer"
config.BRIDGE_CMD_PREFIX = "cmd/"          -- only relay pushes under this prefix
config.BRIDGE_TELEMETRY_DIR = "telemetry/"
config.BACKOFF_MIN_MS = 1000
config.BACKOFF_MAX_MS = 30000

-- Turtle→controller transport.
-- RESEARCHED 2026-10-01 (correction to an earlier assumption in this file):
-- wireless modems are capped at 64 blocks, degrade in storms, and scale oddly
-- above y=96. WIPED modems have NO length cap and turtles CAN use them.
-- Default to wired. Set TURTLE_ID/CONTROLLER_ID per machine.
config.TRANSPORT = "wired"        -- "wired" | "wireless"

return config
