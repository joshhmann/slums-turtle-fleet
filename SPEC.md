# Slums MC — Autonomous Turtle Fleet: Architectural Specification

**Status:** design spec, pre-implementation
**Date:** 2026-10-01
**Server:** Slums MC Fresh Staging — MC 1.21.1 NeoForge, 303 mods
**Host:** CT 108 (`192.168.0.128`) on Proxmox node `forge01`
**Bridge:** `discopanel-dev-bridge.service` → port 8765

Evidence labels used throughout:
- `[VERIFIED]` — read from the live server this session
- `[RESEARCHED]` — from authoritative docs/mod source, not opened on this server
- `[UNVERIFIED]` — assumed, needs a live test
- `[DECISION]` — needs Josh's call

---

## 1. Goal

A fleet of CC:Tweaked turtles that report for duty autonomously, survive
unattended operation across days, and can be supervised from an in-base
control center — with the majority of supervision automatable from outside
the game world.

### Non-goals

- **Full self-sufficiency with no human in the world.** CC:Tweaked turtles halt
  on chunk unload; `max_websockets=4`; mod fleet code is alpha. A turtle that
  falls in lava is not recoverable without either force-loading or a
  respawner. Target is *high* autonomy, not total. `[RESEARCHED]`
- **Pathfinding / autonomous navigation to detected ore.** No mod in this pack
  provides A*. See §4.4.
- **Replacing Create logistics.** Turtles complement the pipe network; they do
  not become better pipes.

---

## 2. Verified platform facts

Everything in this section was read from the running server on 2026-10-01.

### 2.1 CC:Tweaked `[VERIFIED]`

| Fact | Value |
|---|---|
| Version | 1.120.2 |
| Jar | `cc-tweaked-1.21.1-forge-1.120.2.jar` |
| `http.enabled` | `true` |
| `http.websocket_enabled` | `true` |
| `http.max_websockets` | `4` |
| `max_main_global_time` | 10 ms |
| `computer_threads` | 1 |
| `need_fuel` | `true` |
| `normal_fuel_limit` | 20000 |
| `advanced_fuel_limit` | 100000 |

Resolved HTTP rule order (live, after the 2026-10-01 fix):

```
rule[0]  192.168.0.128  8765  allow
rule[1]  172.18.0.1    8765  allow
rule[2]  $private            deny
rule[3]  *                   allow
```

Rules are evaluated in order, earlier wins. The two bridge allows **must** stay
above `$private`. Config is re-extracted from the pack on **every boot** — a
live-only edit reverts. Patched durably in
`/opt/discopanel/tmp/Slums-MC-Final-1.0.0-server.mrpack`
→ `overrides/config/computercraft-server.toml`.

### 2.2 CC:Tweaked operational constraints `[VERIFIED in-game]`

These were learned by breaking them. They drive the controller design.

1. **`http.websocket()` is synchronous and blocks the coroutine.** The computer
   stops accepting input — it appears frozen. Timeout arg is **milliseconds**.
   → The controller must use `http.websocketAsync()` + `os.pullEvent("websocket_message")`.
   A blocking receive inside the main loop would starve turtle dispatch.
2. **`local` does not persist across CC shell lines.** Every shell line is a
   separate program. Shell testing must use bare globals.
3. **Abandoned sockets leak slots.** A program exiting while holding an open
   socket never sends a close frame; each consumes one of `max_websockets=4`.
   The bridge logs `ConnectionClosedError: no close frame received or sent`.
   → Always `ws.close()`. Budget the 4 slots explicitly.

### 2.3 Networking topology `[VERIFIED]`

```
Minecraft container  172.18.0.2   (bridge network "discopanel-network")
docker bridge gw     172.18.0.1
CT 108 LAN           192.168.0.128
bridge listener      0.0.0.0:8765
```

Both `172.18.0.1:8765` and `192.168.0.128:8765` return
`101 Switching Protocols` from inside the container. `[VERIFIED]`

### 2.4 FTB Chunks `[VERIFIED]`

`config/ftbchunks-world.snbt` → `force_loading` block, live values:

| Key | Value |
|---|---|
| `force_load_mode` | `"always"` |
| `max_force_loaded_chunks` | `150` |
| `hard_team_force_limit` | `0` (none) |
| `max_idle_days_before_unforce` | `0.0d` ← **fixed 2026-10-02**, was `1.0d` |

43 chunks force-loaded, all `minecraft:overworld`.
Active team: `84808571-f0e1-43db-a043-320d13c874bd`.

Read at world load — `/reload` does not apply changes.

> **Note:** this is a *global* setting for all teams. All three teams now keep
> chunks loaded indefinitely. Acceptable on a private server; revisit if the
> server is ever opened up.

### 2.5 Existing world state `[VERIFIED]`

Computers `0`–`6` exist in `world/computercraft/computer/`.

| ID | Contents | Notes |
|---|---|---|
| 0 | `startup.lua`, `turtle-toolbox/`, `basalt.lua` | toolbox |
| 1 | `quarry/`, `turtle-toolbox/`, `basalt.lua` | toolbox |
| 2 | `miner.lua`, `turtle-toolbox/`, `basalt.lua` | turtle (earlier session) |
| 3 | `autofuel.lua`, `turtle-toolbox/`, `basalt.lua` | toolbox |
| 4 | `control.lua`, `send.lua` | rednet miner console, `TURTLE_ID=2` |
| 5 | `rawterm.lua` only | empty — the modem-topped PC |
| 6 | `startup.lua`, `turtle-toolbox/`, `basalt.lua` | newest (`ids.json`) |

**`basalt.lua` (193 KB) is present on computers 0,1,2,3,6 but the Basalt mod
jar is NOT in `mods/`.** `[VERIFIED]` It is inert. Either install the mod
properly on both ends or remove the file. The fleet will **not** be built on
Basalt — see §4.6.

`turtle-toolbox/` is a hand-installed Lua library, not a mod.

### 2.6 Mods that matter `[VERIFIED present + registered this boot]`

| Mod | Version | Role in this design |
|---|---|---|
| CC: Tweaked | 1.120.2 | core |
| Advanced Peripherals | 0.8.1a | turtle capabilities, sensing |
| CC: Terminals | 0.1.1 | terminal without a computer |
| CC: Spatial Projector | 0.1.0 | in-world image projection |
| CC:DirectGPU | 1.0.24 | GPU-rendered terminal — the control center |
| CC:C Bridge | 1.7.3 | Red Router, Animatronic, Scroller |
| Classic Peripherals | 0.6.5 | **Radio/GPS** — turtle position |
| Create | 6.0.10 | power + logistics substrate |
| Create: Factory Logistics | 1.6.0 | pipes/sorting |
| Create: Ultimate Factory | 2.2.4 | renewable ores |
| Create: Ultimine | 1.3.3 | vein mining |
| Create: Aeronautics | 1.3.2 | registers CC peripherals (Simulated/Aeronautics/Offroad) `[VERIFIED in boot log]` |
| FTB Chunks | 2101.1.22 | force-loading |
| KubeJS | 2101.7.2 | server-side scripting surface |

**Mods frequently mistaken for others** `[VERIFIED]`:
- `cc-cbc` = **Create: Big Cannons compat** — exposes a cannon mount peripheral. Not a cable mod. The string "cable" does not appear in the jar.
- `cc_sable` = **Create: Sable compat** — read-only sublevel/aero physics APIs. No peripherals, no networking.

---

## 3. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ CT 108 (192.168.0.128)                                      │
│                                                              │
│  dev-bridge (Python, :8765)                                 │
│    • token auth on first message                            │
│    • file-backed: reads/writes /opt/discopanel/dev-bridge/  │
│      files/ ; pushes `update` on change                     │
│    • 128 KB message + file caps                              │
│                                                              │
│  [optional] dashboard HTTP service  ← exposure TBD          │
└───────────────▲──────────────────────────┬───────────────────┘
                │ WebSocket                │ WebSocket
                │ (CC allows rule above)   │
┌───────────────┴──────────────────────────▼───────────────────┐
│ IN-WORLD                                                      │
│                                                              │
│  CONTROLLER computer                                         │
│    • fleet state, odometry, job queue                        │
│    • dispatcher: spawn, recall, replace                     │
│    • bridge client (websocketAsync + pullEvent)             │
│    • wired modem ──┬── turtle A                             │
│                    └── turtle B   (vanilla wired modem =    │
│                                    UNLIMITED range)         │
│                                                              │
│  CONTROL CENTER                                              │
│    • CC:DirectGPU terminal — fleet status, job board        │
│    • CC:Spatial Projector — cosmetic wall display           │
│    • CC: Terminals — outposts, no computer needed           │
└──────────────────────────────────────────────────────────────┘
```

### 3.1 Why wired modems, not wireless `[RESEARCHED]`

Vanilla CC:Tweaked **wired modem networks are unlimited-range**; there is no
length cap in the transmit path. Wireless is capped at **64 blocks**, degrades
in thunderstorms, and scales by altitude above y=96. Critically, **turtles can
use wired networks**; wireless turtle use is awkward.

So: wired modem + cable everywhere. No extra mod required.

> `CC:RJ45` (Modrinth `GZ875jdx`) adds connectors, hubs, and two range tiers for
> suspended/star topologies. **Not installed.** Would need client+server.
> `[DECISION]` — recommend deferring; vanilla cable is sufficient at base scale.

### 3.2 Why not a web dashboard as the primary control surface `[DECISION]`

The in-world DirectGPU terminal works with zero network exposure. That removes
the tailnet-vs-LAN-vs-Caddy decision (§8) from the critical path entirely. A
web dashboard becomes an optional remote/mobile view over the same data files,
not a prerequisite.

---

## 4. Capability analysis

### 4.1 Advanced Peripherals — what to use `[RESEARCHED, source tag 1.21.1-0.8.1a]`

**Tier 1 — earns its slot:**

| Peripheral | Capability |
|---|---|
| `weak_automata` | `digBlock`, `useOnBlock`, `lookAtBlock/Entity`, `updateBlock`, `scanItems`, `collectItems`, `collectSpecificItem`, `chargeTurtle`, `placeBlock`, `setFuelConsumptionRate`, cooldown getters. Item-aware replacement for vanilla `dig`/`detect`/`suck`. |
| `compass` | `getFacing()`. **Mandatory** for `placeBlock`. |
| `geo_scanner` | `scanBlocks(radius)` → positions w/ turtle-relative `f/r/u`; `chunkAnalyze(filter)` → ore census |
| `block_reader` | `getBlockName/State/Data`, `hasBlockEntity`. Free, no cooldown. |
| `me_bridge` / `rs_bridge` | `importItem/exportItem/importFluid/exportFluid`, `craftItem`, `isOnline`, storage + energy accounting. **Unified API in 0.8.** |
| `player_detector` | `getOnlinePlayers()`, `getPlayerData`, `getPlayerInventory`, events |
| `end_automata` | `savePoint`, `warpToPoint`, `estimateWarpCost` — instant recall |
| `chunky_turtle` | force-loads the turtle's own chunk |
| `environment_detector` | `getBiome/Time/LightLevel/MoonPhase/Weather/Dimension` |

**Tier 2 — situational:** `distance_detector` (block-only, stationary),
`inventory_manager`, `nbt_storage`, `energy/fluid/gas_detector`, `chat_box`,
`saddle` (capture/release), `smart_rail`.

**Do not plan around:** `redstone_integrator` — documented but **commented out
of the 0.8.1a build**. Only orphaned models/lang remain. Use CC's own
`redstone` peripheral.

**Do not exist at all:** Magnet, Ore Detector, Point Feed, Chunky Potion,
Magic Tuner. These are third-party CC:Sensors-style names, not AP.

### 4.2 AP naming traps `[RESEARCHED]`

- **0.8 renamed peripherals `camelCase` → `snake_case`.** Old scripts break.
- `fingerprint` keys → `nbt`; AP now uses CC's `nbtHash`.
- A **disabled** peripheral still wraps successfully but every method throws;
  only `peripheralDisabled` exists. Guard: `if p.peripheralDisabled then ... end`.
- Peripherals are server-disablable per type in
  `config/Advancedperipherals/peripherals.toml`. **Read this file before sizing
  scan loops.**
- AP 0.8 declares itself **alpha**: "any implementation or function can change."

### 4.3 Live scan limits `[VERIFIED from server peripherals.toml]`

```
scanBlocksCooldown        2000      # 100 s wall-clock
scanBlocksMaxFreeRadius     8      # 0 fuel cost
scanBlocksMaxCostRadius    16      # beyond this → error
scanBlocksExtraBlockCost  0.17
```

Cost for radius r in 8..16: `floor(((2r+1)³ − 17³) × 0.17)` fuel points.
Cooldown is a **wall-clock timestamp** per upgrade, not fuel-linked — so each
turtle may carry its own scanner, but one turtle cannot scan fast.

### 4.4 The navigation gap — stated plainly `[RESEARCHED]`

- `geo_scanner.chunkAnalyze` returns `Map<blockName, count>` — **counts only,
  no coordinates.** It answers *"is diamond in this chunk and how much"*. You
  cannot drive a turtle to ore from it.
- Positions require `scanBlocks(radius)` — capped at 16, 100 s cooldown.
- **AP contains no pathfinding whatsoever.** No A*, no waypoint following.
- Turtle position is **not readable from Lua**.

**Mitigation:** Classic Peripherals ships `radiogps.lua` — a Radio peripheral
providing GPS position. `[UNVERIFIED in-game]` This is the intended answer to the
odometry gap. If it does not work, the controller must maintain odometry by
counting moves (fragile, drift-prone) and accept that.

**Design consequence:** the controller owns the map. Turtles are dumb, cheap,
expendable workers. This is not a limitation to work around — it is the correct
architecture for a large fleet, and it is why "rookie dispatcher" (§5.3) is the
right pattern.

### 4.5 Positioning — the resolver, not a plan

AP can *detect* ore. It cannot *navigate* to it. Two candidate approaches:

| Approach | Status |
|---|---|
| **Turtle-space scanning** — `scanBlocks(8)` from the turtle, dig what it finds | Simple, local, proven API. Requires no global position. |
| **Global waypoint dispatch** — controller holds a mine plan, walks turtles to waypoints | Needs position. Blocked on Radio GPS verification. |

**[RECOMMENDATION]** Start with turtle-space scanning. It is self-contained and
needs nothing unverified. Add waypoint dispatch only after Radio GPS is proven.

### 4.6 Terminal stack

- **CC:DirectGPU 1.0.24** — real GPU terminal. Bundles `directgpu.lua`,
  `directgpu_term.lua`, `gpu_term_test.lua`. **Requires client-side install** to
  render, so every viewer needs the mod (already in both trees `[VERIFIED]`).
- **CC:Spatial Projector 0.1.0** — `SpatialProjectorPeripheral`, projects images
  onto world blocks. Cosmetic.
- **CC: Terminals 0.1.1** — `TerminalPeripheral`, a terminal on a block with no
  computer. For outposts.
- **Basalt** — present as a file, **mod absent**. Not to be used for the
  controller. Controller should be boring, well-understood Lua; Basalt's value is
  on a human operator terminal, and only once the mod is actually installed.

---

## 5. Component specification

### 5.1 Bridge (CT 108) — `EXISTS, VERIFIED WORKING`

```python
# protocol, from /opt/discopanel/dev-bridge/bridge.py
register  {type, token, client_id}  -> ack {type:"ack", action:"register", client_id}
write     {type:"write", path, content} -> ack {type:"ack", action:"write", path}
server→client  {"type":"update", client_id, path, content}   # on file mtime/size change
server→client  {"type":"error", "error": "<truncated 256>"}
```

- First message **must** be `register` with a valid token, else connection is
  rejected with `register with valid token required`.
- `client_id` must match `^[A-Za-z0-9_.-]{1,64}$`; duplicates rejected.
- Paths must stay within bridge root; `..`, absolute, and symlinks rejected.
- Token source: `/etc/discopanel-devbridge.env` (`DISCOPANEL_TOKEN`, mode 600,
  root-only). Also `DISCOPANEL_TOKEN` env var.

**End-to-end proof `[VERIFIED]`:** in-game CC computer connected to
`ws://192.168.0.128:8765/`, sent `{"type":"register"}`, received
`register with valid token required` — correct response, proving transport.

### 5.2 Controller computer

Single responsibility: own the fleet's state and the only outbound socket.

**Modules:**

| Module | Responsibility |
|---|---|
| `fleet/config.lua` | single source of truth; `MODE`, identity, timings, URLs |
| `fleet/net.lua` | bridge client. **Must** use `websocketAsync` + `os.pullEvent`. Token read from a **file**, never inlined. Reconnect with capped exponential backoff. Always `ws.close()` on shutdown. |
| `fleet/state.lua` | fleet table: per-turtle `{id, pos, fuel, job, last_seen, status}` |
| `fleet/controller.lua` | main loop: heartbeat collection, dispatch, job execution |
| `fleet/odometry.lua` | position bookkeeping (fallback if Radio GPS unverified) |
| `fleet/verbs.lua` | allowlisted job implementations |
| `fleet/errors.lua` | bounded error reporting; never unbounded log growth |

**Hard requirements:**
- Exactly **one** WebSocket. Budget leaves 3 slots unused — deliberate, so an
  operator laptop can connect without starving the controller.
- Reconnect: backoff `1000ms → 30000ms`, capped.
- Never block. No synchronous `ws.receive()` in the main loop (§2.2).
- Every job carries an **id** and is idempotent — a retry must not double-excute.
- Heartbeat timeout `45000ms` → mark offline. `[config.lua baseline]`

### 5.3 Turtle worker

**Modules:** `config.lua` (MODE=turtle), `turtle_startup.lua`, `verbs.lua`, `errors.lua`.

Loop: announce heartbeat → await job → execute → report result → repeat.

**Rookie dispatcher** (the expendable-turtle model):
1. Controller notices heartbeat lapse after `OFFLINE_MS`.
2. If a spare turtle item is in the chest, `turtle.place()` a replacement.
3. New turtle announces, gets an id, receives a job.
4. Lost turtles are not mourned. That is the point.

`end_automata.warpToPoint` gives instant recall-to-base for refuel/repair.

### 5.4 Control center

Reads the same JSON the web dashboard would read — one source of truth, two
renderers, so they cannot disagree.

- **DirectGPU terminal** — fleet table, job queue, fuel levels, alerts.
- **Spatial Projector** — cosmetic wall display of the same data.
- **CC: Terminals** — outposts.

---

## 6. Data contracts

All under bridge root `/opt/discopanel/dev-bridge/files/`. 128 KB cap per file.

### 6.1 `telemetry/fleet.json` — controller writes, dashboards read

```json
{
  "version": 1,
  "updated_epoch": 1759400000,
  "controller": { "id": "fleet-ctrl", "bridge": "connected", "uptime_s": 3600 },
  "turtles": [
    {
      "id": "T01", "status": "working", "job": "mine_copper",
      "job_id": "j-1042",
      "pos": { "x": 118, "y": -34, "z": -207, "source": "radio_gps" },
      "fuel": { "current": 1420, "max": 20000 },
      "inventory": { "used_slots": 4, "total_items": 96 },
      "capabilities": ["weak_automata", "geo_scanner", "compass"],
      "last_seen_epoch": 1759399990
    }
  ]
}
```

`pos.source` is `"radio_gps"` or `"odometry"` — honest labelling of which
mechanism produced it.

### 6.2 `jobs/queue.json` — operator writes, controller consumes

```json
{
  "version": 1,
  "jobs": [
    { "id": "j-1043", "verb": "mine", "target": "minecraft:copper_ore",
      "params": { "max_blocks": 500, "radius": 8 }, "priority": 50,
      "assigned_to": null, "state": "queued" }
  ]
}
```

Controller transitions `state`: `queued → assigned → running → done|failed`.
**Never re-executes a `done`/`failed` job id.** Human edits this file; the
controller owns the transition, so a hand-edit can't double-run work.

### 6.3 `logs/events.jsonl` — append-only

One JSON object per line: `{epoch, turtle, level, event, detail}`. The
controller rotates at a size cap. Diagnostics only — the dashboard should
degrade gracefully if this file is missing.

---

## 7. Failure modes and recovery

| Failure | Detection | Response |
|---|---|---|
| Bridge process dies | reconnect attempts exhaust backoff | backoff, keep turtles running on last-known jobs |
| Bridge unreachable from CC | CC rules / service state | alert on dashboard; turtles autonomous |
| Token invalid | `error: register with valid token required` | halt reconnect loop, surface clearly, do not spam |
| Turtle heartbeat lapses | `last_seen > 45000ms` | mark offline, dispatch replacement |
| Turtle dies (lava/caved) | heartbeat lapse | rookie dispatcher replaces it |
| Controller chunk unloads | FTB force-load | prevented by §2.4; **verify turtle chunks are inside the loaded set** |
| Turtle strays outside force-loaded set | turtle goes silent | **known silent failure mode — check first** |
| WebSocket slots exhausted | bridge rejects new connections | only one controller socket by design (§5.2) |
| AP peripheral disabled server-side | `p.peripheralDisabled` truthy | guard in code; report capability as unavailable |
| Scan cooldown 100 s | turtle appears unresponsive | expected; do not retry-scan |

**Critical unverified risk:** force-loading only helps if turtles are actually
*inside* the force-loaded chunk set. 43 chunks are loaded; a turtle one chunk
outside halts silently. **Verify per-turtle on first deploy.**

---

## 8. Open decisions `[DECISION]`

1. **Dashboard exposure** — currently *not blocking*, since the in-world
   DirectGPU terminal is primary. If a web view is wanted:
   - CT 108 has **no Tailscale client** and neither does `forge01` `[VERIFIED]`.
     CT 118 (Caddy) was unreachable at time of writing.
   - Options: **(a)** LAN-only bind `192.168.0.128:8770` — immediate, reachable
     by any LAN device. **(b)** Caddy-gated once CT 118 is back. **(c)** install
     Tailscale into CT 108 — matches standing preference for tailnet-only, but
     modifies the container running the game server and panel; not to be done
     unilaterally.
   - Recommendation: **(a) now, (c) later.**
2. **Installer host** — GitHub raw recommended over pastebin.com (rate limits,
   stability). Confirm.
3. **Basalt** — install the mod properly, or delete `basalt.lua` from computers
   0,1,2,3,6? Currently inert either way.
4. **CC:RJ45** — defer, or add for star-topology cabling?
5. **Radio GPS** — verify in-game before designing around it (§4.4).

---

## 9. Phasing

Each phase ends in something observable. No phase assumes a later one worked.

**Phase 0 — transport `[DONE]`**
CC:Tweaked → bridge WebSocket, verified from a real in-game computer. Server
pack patched durably; FTB idle-unforce fixed to `0.0d`.

**Phase 1 — one computer, one turtle, one job**
Place turtle + wired modem near the PC. Write fresh controller + worker. Prove:
heartbeat visible, one `move` command executes, `ws.close()` runs so no slot leaks.
*Requires Josh in-world.*

**Phase 2 — job board**
`jobs/queue.json` round-trip. Controller consumes, dispatches, reports. Idempotent
job ids proven by a deliberate duplicate submit.

**Phase 3 — capability**
`weak_automata` digging, `geo_scanner` census, `block_reader`. Prove a turtle
mines and reports inventory. Verify Radio GPS for position.

**Phase 4 — force-load survival**
Turtle works a chunk outside immediate view. Confirm it does not halt. **This
is the autonomy test** — it is what makes "runs while I'm in Worcester" true
rather than aspirational.

**Phase 5 — rookie dispatcher**
Death → replacement. `end_automata` recall for refuel.

**Phase 6 — control center**
DirectGPU terminal + Spatial Projector reading `telemetry/fleet.json`. Optional
web view over the same files.

**Phase 7 — logistics**
`me_bridge`/`rs_bridge` item transfer; turtles as haulers into Create pipes;
`createultimine` for veins.

---

## 10. Bootstrap installer

**Goal:** rebuild a fleet in minutes without manual file entry.

CC:Tweaked computers can `http.get()`, so a single paste can fetch a library,
write `fleet/`, and install `startup.lua`.

```
paste #1  bootstrap   fetch library, write fleet/, set startup.lua, verify version
paste #2  controller  deploy on the PC
paste #3  worker      deploy on each turtle
paste #4  undo        remove fleet/, restore prior startup.lua
```

Rules baked in:
- Fetch library once, cache locally, **version check** — changing the paste must
  not require re-pasting everything.
- **Read-only default:** controller accepts only allowlisted verbs.
- **Undo paste** — a system that installs itself should remove itself cleanly.
- Idempotent: safe to re-run; overwrites its own files only, touches nothing else.
- Print a manifest of what was written and what was skipped.

---

## 11. Backups taken this session

```
/opt/discopanel/backups/
  Slums-MC-Final-1.0.0-server.mrpack.before-ccrules-20261001-183210
  computercraft-server.toml.before-ccrules-20261001-183210
  ftbchunks-world.snbt.before-unforce-20261002-004736
```

---

## 12. Corrections log

Recorded because the errors were mine and future sessions should not repeat them.

1. **Claimed the CC rules fix was already applied.** It was applied to the
   *client distribution tree only*. The server pack never received it, and
   reverts on every boot. Verified by hash comparison of both copies.
2. **`local` in the CC shell does not persist between lines.** Presented a
   four-line test where `local ws` died at the line boundary, producing a `nil`
   that looked like a network failure. The connection had actually succeeded.
3. **Misread `cc-cbc` as a cable mod.** It is Create: Big Cannons compat. Built
   a whole architecture on the acronym. `cc_sable` likewise is physics compat.
   The real answer — vanilla wired modems are unlimited-range — is better and
   needs no mod.
4. **Named AdvancedPeripherals peripherals that don't exist** (Magnet, Ore
   Detector, Point Feed, Chunky Potion, Magic Tuner), and cited
   `redstone_integrator` which is commented out of the 0.8.1a build.
5. **Suggested a physical dispenser for turtle deployment.** Dispensers cannot
   place entities from items; `turtle.place()` is the correct mechanism and
   additionally enables replacement-on-death.
6. **Overstated Basalt's presence** — 193 KB file on five computers, mod jar
   absent. Initially read the file as evidence the framework was working.