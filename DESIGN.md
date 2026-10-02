# CC:Tweaked Turtle Fleet Control — Engineering Design

**Status:** Phase 0 (research/architecture) + Phase 1 (one-turtle PoC) design
**Author:** Mai
**Date:** 2026-09-29
**Live server changes:** none. This document and the Phase-1 code are artifacts only.

---

## 0. TL;DR

- **Option B is correct**, and not merely preferred — Option A is *technically* worse for
  three concrete reasons (chunk unloading, `max_websockets`, and handler starvation). Details in §2.
- The **decision layer / execution layer split you described is the right shape** and the CC
  runtime actually enforces it: a turtle's verbs are synchronous and return `boolean, reason`,
  which maps cleanly onto deterministic execution with no LLM in the loop.
- The single most important reliability fact: **CC computers stop executing when their chunk
  unloads, and re-run `startup.lua` when it loads again.** "Offline" is therefore *normal and
  constant*, not an error. Every retry/timeout policy must be built around that, not around
  TCP-like assumptions.
- Phase 1 should be split into **1a (turtle ↔ controller over rednet, no HTTP)** and
  **1b (add the WebSocket bridge)**. 1a is where all the risk is; it is also testable without
  a network service. The success condition you specified is fully satisfiable at 1a.
- A bug in my earlier prototype: I assumed `http.websocket` was asynchronous and waited for
  `http_success`/`http_failure`. **It is synchronous** (`@changed 1.80pr1.3 No longer
  asynchronous`). Only `http.websocketAsync` queues `websocket_success`/`websocket_failure`.
  The corrected code is in §11.

---

## 1. Recommended architecture

```
  User / Agent / Web UI          ← intent, fleet-level verbs
        │  HTTP / WebSocket
        ▼
  Fleet Controller               ← scheduling, state, retries, idempotency
  (one stationary CC computer, force-loaded)
        │  rednet (wireless modem)
   ┌────┼────┬────────┐
   ▼    ▼    ▼        ▼
  T01  T02  T03      Tnn         ← deterministic execution, no LLM
```

**Hard boundary, enforced on the turtle side:**

| Layer | Owns | Must never |
|---|---|---|
| Agent / Web UI | intent, "mine this region", "recall T03" | issue thousands of `forward()` calls |
| Controller | registry, scheduling, job ownership, retries, dedupe | execute movement itself |
| Turtle | movement, safety, fuel, inventory, recovery, reporting | accept arbitrary code; trust the controller's allowlist |

The turtle validates its own action allowlist. The controller is *not* trusted — rednet is
unauthenticated and trivially spoofable (§3.6).

---

## 2. Why B, not A

You asked whether there's a *strong technical reason* for B. There is — three of them.

### 2.1 Chunk unloading kills direct-connect turtles

A CC computer only executes while its chunk is loaded. A mining turtle by definition leaves
its home chunks. Under **A**, every turtle must hold a live WebSocket, which means it must be
running, which means its chunk must be loaded — so you must force-load a moving turtle's chunk
for the entire duration of every job.

Under **B**, the turtles are *allowed* to blink out. They re-announce on reload (startup
re-runs), the controller reconciles, and the fleet keeps working. The controller is the only
thing that needs a force-loaded chunk (one FTB Chunks claim, already available in the pack).

This is the decisive argument. It is a structural property of the platform, not a preference.

### 2.2 `max_websockets = 4` caps the fleet size

Server config: `max_websockets = 4` **per computer**. Under A, that is 4 turtles per... nothing
— each turtle gets its own 4, so the per-turtle cap isn't the binding limit. The real binding
limit under A is the bridge: `CLIENT_ID` uniqueness and one socket per client.

The stronger argument is **request/queue budget** (`max_requests = 16`) and, more importantly,
that every turtle then needs the bridge's token. A shared secret distributed to N roaming
turtles is not a secret. Under B, exactly one machine holds the token — the one inside a
force-loaded, access-controlled base.

### 2.3 One blocking handler in `bridge.py` cannot serve a fleet

The existing bridge is a single `async for raw in ws` loop **per connection**, and its
`watch()` loop pushes every changed file to every client:

```python
for client_id, ws in tuple(self.clients.items()):
    await self._send(ws, {"type": "update", ...})
```

That is `O(clients)` per changed file, every 0.5s, with head-of-line blocking on a slow client.
Ten turtles = ten sockets competing for one Python process that also does disk I/O per message.
Under B, the bridge serves **one** client and the fan-out happens in rednet, which is designed
for it.

### 2.4 Counter-argument, stated fairly

**B adds a hop and a second failure domain.** A turtle can be perfectly healthy while the
controller is unloaded, and then the turtle is unreachable with no way to discover that from
outside. Mitigation: the controller is the one machine we force-load, and it is stationary.
That single point of control is also a single point of failure — accepted deliberately, because
it converts "N unobservable failures" into "1 observable failure".

### 2.5 Verdict

**B.** A is only preferable if you want zero infrastructure and ≤2 turtles that never leave
loaded chunks. That is not the stated trajectory.

---

## 3. CC:Tweaked networking constraints that actually matter

Verified against CC:Tweaked source (`mc-1.21.x` branch) and this server's live config.

### 3.1 `http.websocket` is synchronous — `websocketAsync` is not

```lua
-- synchronous: blocks, returns (ws) or (false, err)
local ws, err = http.websocket("ws://host:port/")

-- asynchronous: returns immediately, queues websocket_success / websocket_failure
http.websocketAsync(url)
```

Source comment: `@changed 1.80pr1.3 No longer asynchronous`. **Do not** wait for
`http_success` after calling `http.websocket` — you will hang. This was a real bug in my first
prototype and is the single easiest mistake to make here.

### 3.2 Holding a socket across a blocking rednet call loses events

`rednet.receive(protocol, timeout)` loops on `os.pullEvent(event_filter)`. Events are delivered
to Lua coroutines by the machine; a coroutine blocked in one event source does not service
another. So the naive "keep the socket, also call rednet.receive" loop **starves the socket**.

**Correct pattern — two coroutines:**

```lua
parallel.waitForAny(
  function() wsLoop()   end,   -- owns the socket
  rednet.run                    -- BIOS already runs this; own it explicitly
)
```

`parallel` pulls one event and resumes *every* coroutine with it, so a coroutine waiting on
`websocket_message` and one waiting on `rednet_message` both make progress. Cross-coroutine
communication goes through plain shared tables (inbound/outbound queues), never through a
blocking call.

### 3.3 Computers halt on chunk unload — "offline" is normal

On reload, `bios.lua` re-runs `startup.lua` (when `settings.shell.allow_startup` is true, the
default). Consequences:

- Turtles must **announce on boot**, every boot. There is no persistent session.
- The controller must treat absence as expected, and must handle a turtle re-announcing with a
  stale job it was mid-way through.
- `startup.lua` must be **idempotent and crash-safe** — it will run many times.

### 3.4 Modem range is a hard physical limit

Live config: `modem_range = 64`, `modem_high_altitude_range = 384`,
`modem_range_during_storm = 64`.

**64 blocks** is nothing for a mining fleet. Two options:

- **Ender Modem** (`advanced wireless modem`, `wireless_modem_advanced`) — unlimited range,
  works across dimensions. Confirmed present in the installed CC:Tweaked build.
- Keep every turtle within 64 blocks of the controller, which forbids roaming.

**Use Ender Modems.** This is a hardware requirement for the stated vision, and it is cheaper
to choose now than to discover at 70 blocks.

### 3.5 `textutils.serialiseJSON` has sharp edges

- An **empty table serialises as `{}`, not `[]`**. There is no way to force an empty array
  without a sentinel. Any JS-side consumer must accept `{}` for "no items".
- Sparse tables (nil holes) are undefined; never build them.
- Numbers round-trip as JSON numbers, but `turtle.getFuelLevel()` returns the **string**
  `"unlimited"` when fuel is disabled. Handle it explicitly — `need_fuel = true` here, but the
  code should not assume it.
- Field order is not preserved.

### 3.6 rednet is unauthenticated and spoofable

The CC docs are explicit: *"it doesn't provide any guarantees about security. Other computers
could be listening in to your messages, or even pretending to send messages from other
computers!"*

On a private friend server this is a nuisance, not a breach — but it means **the turtle must
validate before acting**, and the allowlist must live on the turtle. Optionally add a shared
nonce/HMAC in `auth`, but do not pretend rednet is a secure channel.

### 3.7 Compute budget: 1 thread, 5 ms/computer/tick

`computer_threads = 1`, `max_main_global_time = 10`, `max_main_computer_time = 5`.

One thread for **all** computers on the server. A busy-wait loop in any turtle steals tick
budget from every other computer and from the server. Consequences:

- No polling loops. Use event waits with timeouts.
- `os.sleep(0)` / tight retry loops are forbidden.
- A "heartbeat every 500 ms" loop is *fine when idle* (it sleeps), but never spin.

### 3.8 The bridge's `watch()` has an initial sync storm

`_snapshots` starts empty, so on the first `watch()` pass **every existing file under the root
is pushed to every client**. Keep the bridge root nearly empty, and have consumers filter on a
path prefix (`cmd/`) rather than trusting that every push is new.

### 3.9 The bridge is push-only today

Verified by reading `bridge.py`: `_handler` accepts exactly `register` and `write`. A `read` or
`list` message returns `{"type":"error","error":"unknown message type"}` — confirmed
empirically. So the controller can write telemetry (fire-and-forget) but cannot pull state.
This is workable for Phase 1; §9 recommends a small `read` addition for Phase 3.

---

## 4. Proposed message protocol

Transport: JSON via `textutils.serialiseJSON`, over either rednet (controller↔turtle) or
WebSocket text frames (controller↔bridge). Same envelope shape at both layers, so the
controller is a translator, not a transformer.

### 4.1 Command (controller → turtle)

```json
{
  "v": 1,
  "id": "T01-0001042",
  "action": "forward",
  "args": {},
  "deadline_ms": 5000
}
```

`id` **must** be globally unique per controller session and stable across retries. Format:
`<turtle>-<boot-epoch>-<counter>`. This is what makes retries safe.

### 4.2 Response (turtle → controller)

Success:

```json
{ "v": 1, "id": "T01-0001042", "turtle": "T01", "ok": true, "result": {}, "state": { } }
```

Failure:

```json
{ "v": 1, "id": "T01-0001043", "turtle": "T01", "ok": false,
  "error": "movement_obstructed", "detail": "minecraft:gravel", "state": { } }
```

`state` rides along on every response so the controller's registry stays fresh for free.

### 4.3 Error taxonomy (closed set)

| `error` | Cause |
|---|---|
| `movement_obstructed` | `forward/up/down` returned `false`, block present |
| `unbreakable_block` | `dig` returned `false`, bedrock/claim |
| `out_of_fuel` | `getFuelLevel() == 0` |
| `inventory_full` | no free slot for a dig/suck |
| `nothing_to_dig` | `dig` on air |
| `nothing_to_inspect` | `inspect` out of range |
| `unsupported_action` | not in the turtle's allowlist |
| `bad_args` | args missing/out of range |
| `turtle_api_missing` | `turtle` table absent (program ran on a computer) |
| `internal_error` | caught Lua error; `detail` carries the message |

A closed set matters: it makes `lastError` comparable across turtles and lets the fleet manager
classify "stuck" (repeated `movement_obstructed` at the same coordinate) mechanically.

### 4.4 Telemetry (turtle → controller → bridge)

```json
{
  "v": 1, "turtle": "T01", "state": "idle", "fuel": 823,
  "inventoryFreeSlots": 11, "lastCommand": "forward", "lastError": null,
  "pos": { "x": 117, "y": 67, "z": 456 }, "jobId": null, "ts": 1234567
}
```

`pos` — see §6.3. `ts` is `os.epoch("utc")` (wall clock), not `os.clock()`.

### 4.5 Control plane (bridge/agent → controller)

```json
{ "v": 1, "id": "cmd-1042", "action": "forward", "turtle": "T01", "args": {} }
{ "v": 1, "id": "job-22", "action": "tunnel", "turtle": "T01", "args": { "length": 64 } }
{ "v": 1, "id": "stop-all", "action": "stop", "scope": "fleet" }
```

The `turtle` field is what distinguishes a per-turtle command from a fleet verb. `action` is
validated against the **same allowlist** as the turtle's, plus a small set of
controller-only verbs (`pause`, `resume`, `recall`).

### 4.6 Idempotency contract

- Every command carries a unique `id`.
- The turtle keeps a **bounded ring buffer of the last 32 `(id, response)` pairs**.
- On a repeated `id`, the turtle **re-sends the cached response and does not re-execute**.
- Idempotency is required at the *command* level, not the verb level: `forward` is not
  idempotent (running it twice moves two blocks), which is exactly why the `id` must be
  honoured before any verb dispatch.

This is the mechanism behind your requirement: *"A turtle should never blindly execute the same
movement command twice merely because the controller retried a message."*

---

## 5. Turtle state machine

```
        ┌──────────┐
        │  BOOT    │  startup.lua runs (again) after chunk reload
        └────┬─────┘
             │ read/derive ID  ── fail ──▶ ID_ERROR (halt, report once)
             ▼
        ┌──────────┐
        │ SELF_ID  │  label or /fleet/config.lua; verify it's a turtle
        └────┬─────┘
             │ open modem ── fail ──▶ NO_MODEM (halt)
             ▼
        ┌──────────┐  ANNOUNCE (broadcast) then LISTEN
        │  IDLE    │◀──────────────────────────────┐
        └────┬─────┘                               │
             │ command received                    │
             ▼                                     │
        ┌──────────┐  duplicate id ──▶ re-send cached response
        │ VALIDATE │  bad action ────▶ UNSUPPORTED → IDLE
        └────┬─────┘  bad args ──────▶ BAD_ARGS    → IDLE
             ▼
        ┌──────────┐
        │ EXECUTE  │  (deterministic; no network inside)
        └────┬─────┘
             ├── ok ──────────────▶ report result → IDLE
             ├── recoverable ─────▶ RECOVER (bounded) → EXECUTE or IDLE
             └── fatal condition ─▶ FULL / OUT_OF_FUEL / STUCK (latched, reported)
```

Side-state (latched conditions, cleared only by an explicit verb):

| State | Entered when | Cleared by |
|---|---|---|
| `inventory_full` | a dig/suck would fail for space | `drop`/`deposit`, or slot freed |
| `out_of_fuel` | `getFuelLevel() == 0` | `refuel` / `refuel_from_chest` |
| `stuck` | 3 consecutive `movement_obstructed` on the *same* action | any successful move, or `stop` |
| `halted` | `stop` (fleet or per-turtle) | `resume` |

**Only `stop` is unconditional.** A halted turtle ACKs `stop` and refuses every verb except
`status` and `resume`, so the halt cannot be defeated by a queued command.

### 5.1 `stop` semantics

- `{"action":"stop","scope":"fleet"}` → broadcast on the stop protocol; every turtle latches
  `halted`. The controller additionally **drops its own outbound queue** so nothing is sent
  after the halt.
- `{"action":"stop","turtle":"T03"}` → targeted; only T03 latches.
- The turtle also checks the halt flag **between every verb in a job** (Phase 2), so a
  long-running `tunnel` aborts at the next block rather than running to completion.

---

## 6. Controller state model

### 6.1 Registry

```lua
registry[T01] = {
  id = "T01",
  last_seen,          -- os.epoch("utc") of last message
  online,             -- last_seen > now - OFFLINE_MS
  state,              -- idle | executing | stuck | full | out_of_fuel | halted
  fuel, inventoryFreeSlots,
  lastCommand, lastError,
  pos = {x,y,z},
  jobId = nil,
  inflight = { id, sent_at, attempts },   -- at most one
  history = { ... }                        -- bounded ring buffer
}
```

`online` is **derived**, never stored as truth. There is no "connected" event for a turtle that
unloads mid-session (§3.3), so presence is only ever inferred from recency.

### 6.2 Command queue and in-flight tracking

- `queue` — bounded (default 32). Overflow → reject with `queue_full`; never grow unbounded.
- **At most one in-flight command per turtle.** A turtle is single-threaded; pipelining
  movement commands to a machine executing them sequentially is how you get a turtle to dig
  into lava.
- Retry: re-send the *same `id`*. The turtle dedupes (§4.6), so a re-send after a lost
  response is safe — the turtle replays the cached answer instead of moving again.

### 6.3 Position tracking — read this before trusting coordinates

CC:Tweaked exposes **no world coordinates** to a plain turtle. `os.getComputerID()` is not a
position. Therefore initial `pos` is `nil`, and any position the controller shows is a
**dead-reckoned estimate** from successfully executed movement verbs.

It drifts, and it drifts silently, on: failed moves that were still counted, chunk reloads
(state lost), teleports, and any manual player intervention.

A robust Phase-3 answer is a **GPS constellation** (`GPS.locate`, 4 GPS hosts) which gives true
position — but that is a separate build. For Phase 1: report dead-reckoned `pos` as a *hint*,
and mark it `estimated = true` in telemetry. Do not build stuck-detection on it alone.

### 6.4 Boot epoch for idempotency

On every controller boot, generate `boot_epoch = os.epoch("utc")`. All command ids embed it.
If the controller restarts, ids from the previous session are never reused, so a turtle's
dedupe cache cannot collide across controller restarts.

---

## 7. Reconnect / retry strategy

The governing insight: **rednet has no connection.** There is nothing to reconnect. All the
"reconnect" logic belongs to the controller↔bridge WebSocket; all the "retry" logic belongs to
the controller↔turtle command layer.

### 7.1 Controller → bridge (the only real reconnect)

| Event | Behaviour |
|---|---|
| socket drops | reconnect with exponential backoff 1s→2s→4s→…→30s cap, jittered |
| register rejected (bad token) | fatal, log, do **not** hot-loop — alerts a human |
| `client_id already connected` | previous socket not reaped; wait `backoff`, reconnect (the bridge frees the id when the old socket closes) |
| reconnect succeeds | re-register, then **re-announce fleet state** so the bridge isn't stale |

Note the bridge's `client_id` uniqueness means a fast restart can collide with your own ghost.
Use a stable id plus a short backoff, not a random id — a random id would leak sockets.

### 7.2 Controller → turtle (timeout + idempotent retry)

| Situation | Behaviour |
|---|---|
| no response within `deadline_ms` | re-send the **same id**, up to `MAX_ATTEMPTS` (3) |
| still nothing | mark turtle `offline`, requeue or fail the job |
| duplicate response | ignore (matching `id` already resolved) |
| turtle re-announces | treat as a fresh registration; if it had a job, mark it `interrupted` and let the scheduler decide |
| malformed message | log, drop, do not crash; count against a per-turtle budget |

Backoff between attempts: 1s, 3s, 8s (not a tight loop — `max_main_computer_time = 5`, §3.7).

### 7.3 Turtle side

| Event | Behaviour |
|---|---|
| boot | announce immediately, then listen |
| no controller for N s | stay `idle`; do not spin, do not escalate |
| malformed command | reply `bad_args`/`unsupported_action`, stay `idle` |
| duplicate id | replay cached response |
| internal Lua error | catch, reply `internal_error`, stay alive |

Rule: **the turtle never dies from bad input.** Every dispatch is `pcall`-wrapped (§11).

---

## 8. Suggested Lua file/module layout

CC has no package manager; module layout is `require`-by-path with `dofile`. Keep it flat and
explicit — deep trees waste the 1 MB `computer_space_limit` and are miserable to `edit`.

```
/fleet/
  config.lua        -- TURTLE_ID/MODE, CONTROLLER_ID, PROTOCOL, BRIDGE_HOST/PORT, TOKEN_FILE
  net.lua           -- envelope encode/decode, version check, id minting, dedupe ring buffer
  errors.lua        -- the closed error taxonomy (§4.3) as constants
  log.lua           -- bounded ring-buffer log (no unbounded file growth)
  state.lua         -- turtle state machine + telemetry assembly
  verbs.lua         -- the allowlist: action -> implementation (§11)
  turtle/
    startup.lua     -- boot entry: SELF_ID -> open modem -> announce -> listen loop
  controller/
    startup.lua     -- boot entry: registry + rednet loop + ws loop (parallel)
    registry.lua    -- turtle registry, online derivation, in-flight tracking
    bridge.lua      -- websocket client + reconnect/backoff
    queue.lua       -- bounded command queue, retry policy
  jobs/             -- Phase 2: move.lua tunnel.lua quarry.lua return_home.lua deposit.lua
```

Put `config.lua` on a **disk drive or in the turtle's own FS** and make `startup.lua` read it,
so re-imaging a turtle is "copy config, label it". Never require re-typing a token in-game.

---

## 9. Minimal Phase-1 implementation plan

Deliberately split, because Phase 1a has all the risk and none of the network.

**1a — turtle ↔ controller over rednet (no HTTP).**
1. Turtle: `startup.lua` → SELF_ID, open modem, announce `hello`.
2. Controller (any CC computer with a modem): listen, print the registry.
3. Controller sends `{action="status"}` → turtle replies with full telemetry.
4. Controller sends `{action="forward"}` → turtle moves one block → replies `ok`.
5. Controller sends a duplicate id → turtle replays the cached response, **does not move**.
6. Controller sends `{action="stop"}` → turtle latches halted; further moves refused.
7. Send garbage → turtle replies `bad_args`, stays alive.

**Exit criterion:** step 4 succeeds and step 5 proves no double-move. That is your stated
success condition, minus the WebSocket.

**1b — add the bridge.**
8. Controller gains the WebSocket coroutine: register, then relay `cmd/*` pushes to rednet.
9. Write telemetry back to the bridge via `write` (works today, push-only).
10. Re-run steps 3–7 with the command injected as a file rather than typed.

**Why this order:** if you build 1b first and the turtle doesn't move, you cannot tell whether
rednet, the turtle logic, the socket, or the bridge is at fault. 1a removes three of those.

**Effort estimate:** 1a is one sitting. 1b is a second, much shorter one.

---

## 10. The very small first test (ONE turtle)

**Hardware**
1. One **wireless turtle** (turtle + wireless modem upgrade as *equipment*, or a modem on a
   side block). Use an **Ender Modem** if you want it to ever leave home (§3.4).
2. One CC computer with a modem = the controller. Your existing `computer/4` is this, or a new
   one. **Keep them within 64 blocks** for the first test — that removes range as a variable.

**Setup**
3. On the turtle: `label set T01` (persists in the save, survives reboots).
4. Put **fuel in the turtle** and `refuel` until it reports a healthy level
   (`need_fuel = true`, so an unfuelled turtle fails every move with `out_of_fuel`).
5. Give the turtle clear space ahead — the test digs *or* moves, and starting flush against a
   wall is a `movement_obstructed`, which is a *correct* result but a confusing first run.
6. Install `fleet/` on both machines and run the controller.

**The test, exactly as you specified it**

```
T01 boots            → announces
controller           → sees T01 in the registry
controller → T01     → {"v":1,"id":"T01-1-001","action":"status"}
T01 → controller     → {"ok":true,"state":"idle","fuel":823,"inventoryFreeSlots":11,...}
controller → T01     → {"v":1,"id":"T01-1-002","action":"forward"}
T01 → controller     → {"ok":true,"id":"T01-1-002"}          ← and it MOVED ONE BLOCK
controller → T01     → {"v":1,"id":"T01-1-002","action":"forward"}   ← deliberate retry
T01 → controller     → {"ok":true,...}  same id, AND IT DID NOT MOVE   ← idempotency proven
```

**Pass conditions, all four:**
- registry shows T01 as `online`
- `status` returns plausible fuel and free slots
- `forward` returns `ok:true` **and a human confirms the block moved**
- the duplicate id returns the cached response and the turtle does **not** move again

That last one is the whole point. Without it, you have a demo; with it, you have a control
system.

---

## 11. Phase-1 code

Written and verified: `fleet/` in this directory. Verification performed:

- `luac5.1 -p` syntax check (Lua 5.1 = CC:Tweaked's dialect) — clean
- a stubbed harness simulating CC's APIs (fs, peripheral, rednet, http, textutils, os.pullEvent)
  driving a full command cycle — including the duplicate-id path
- the driver injects a bad/unknown action and asserts the turtle replies `unsupported_action`
  and remains alive

Not performed, and not claimed: no turtle was moved; nothing was written to the live server or
the world save.

**Corrections carried into this code from the prototype:**
1. `http.websocket` treated as **synchronous** (§3.1).
2. Controller uses two coroutines via `parallel.waitForAny`, not a single loop (§3.2).
3. Turtle dedupe ring buffer consulted **before** verb dispatch (§4.6).
4. Ids namespaced by boot epoch so a controller restart cannot alias old ids (§6.4).
5. `pos` marked `estimated` and never treated as truth (§6.3).
6. `getFuelLevel()` handles the `"unlimited"` string (§3.5).
7. Every dispatch `pcall`-wrapped; the turtle cannot be killed by input (§7.3).

---

## 12. Open questions for you

1. **Ender Modems or stay within 64 blocks?** This is a hardware decision and it gates
   everything about roaming. (§3.4)
2. **Which machine is the controller?** Reuse `computer/4`, or a fresh computer in a claimed
   chunk? It must be force-loaded (FTB Chunks) to be a reliable control plane.
3. **One turtle per command, or broadcast?** Broadcast means every turtle in range acts on
   every command. I designed for targeted-by-default with broadcast as an explicit verb.
4. **Lock down the bridge root?** The bridge is LAN-exposed on `0.0.0.0:8765` with one shared
   token, and `write` can create files anywhere under its root. That is the real security
   boundary for the whole chain — worth a deliberate decision before Phase 1b.
5. **Add `read`/`list` to `bridge.py`?** ~20 lines, and it makes the control plane pull-based
   instead of push-only. I'd want your go-ahead since it changes a running host service.
