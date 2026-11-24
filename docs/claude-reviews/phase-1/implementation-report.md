# Phase 1 Implementation Report — Cash Empire Tycoon (Revised)

**Date:** 2026-11-24 (revised from initial review)
**Branch:** `feature/phase-1-data-foundation`
**Commit under review:** `b05aa20e3bdb82a4b842e4d1131cd11a16b37170`
**Reviewer:** Claude Sonnet 4.6
**Status:** Implementation defects identified; redesign approved pending architecture sign-off

---

## Scope

Phase 1 targeted the data persistence layer. No gameplay systems, UI, or monetization were modified.

**Files changed in b05aa20 (3):**

| File | Type of change |
|---|---|
| `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` | Full rewrite |
| `RobloxTycoon/src/ServerScripts/TycoonManager.server.lua` | 5 targeted edits |
| `RobloxTycoon/src/ServerScripts/MapBuilder.server.lua` | 8-line addition |

**Files not changed:** `ShopHandler.lua`, `UpgradeTable.lua`, `HUD.client.lua`, all Rojo configs, all LocalScripts.

---

## Phase 1 Deliverables — Status

| Deliverable | Status in b05aa20 | Notes |
|---|---|---|
| Safe player profile loading | ⚠️ Partial | Load case logic correct; GetAsync has no retry (Defect 4) |
| Protection against saving profiles after failed loads | ✅ Implemented | `loadFailed[userId]` guard on all write paths |
| Session locking | ⚠️ Defective | Two-DataStore design; save doesn't verify ownership at write time (Defect 1) |
| Safe autosaving | ⚠️ Partial | `loadFailed` guard present; session-loss detection absent |
| Safe shutdown handling | ✅ Implemented | Parallel `BindToClose` with 25s deadline |
| Retry and failure handling | ⚠️ Partial | Save retries present; load retries absent (Defect 4) |
| Safe handling of player disconnects | ⚠️ Partial | Save and lock release correct; session-loss kick absent |
| MapBuilder/TycoonManager initialization dependency | ✅ Complete | `ServerStorage.MapReady` signal + `WaitForChild` |
| Removal of unused Heartbeat connection | ✅ Complete | Dead stub at old lines 100–102 removed |

---

## Defects Found in b05aa20

### Defect 1 — Stale server can overwrite live session data (Critical)

**Root cause:** Two-DataStore architecture. Lock in `TycoonSessionLocks_v1`; data in `TycoonPlayerData_v1`. `savePlayer`'s `UpdateAsync` callback ignores `_current` and writes unconditionally. No ownership check at write time.

**Impact:** A server whose lock has expired (e.g., after a failed refresh) can overwrite data belonging to a newer session on another server.

**Location:** `PlayerDataManager.lua`, `savePlayer()`.

**Fix:** Single-key design: embed `_session` inside `TycoonPlayerData_v1`. `savePlayer` callback verifies `current._session.token == sessionTokens[userId]` before writing. Mismatch → abort.

---

### Defect 2 — `refreshLock` failure is undetected (High)

**Root cause:** `pcall` absorbs both DataStore errors and callback-returned-nil (session stolen). Caller cannot distinguish success from failure.

**Impact:** Server may continue operating under a session it no longer owns, then save stale data.

**Location:** `PlayerDataManager.lua`, `refreshLock()` and refresh loop.

**Fix:** `refreshSession` returns a status indicating success, DataStore error, or confirmed session loss. On confirmed loss: set `loadFailed[userId] = true`, kick player.

---

### Defect 3 — `acquireLock` relies on closure mutation with Roblox callback retries (High)

**Root cause:** `acquired = true` is set as a side effect inside the `UpdateAsync` callback. Roblox may invoke the callback multiple times; the final value of `acquired` depends on which invocation ran last.

**Location:** `PlayerDataManager.lua`, `acquireLock()`.

**Fix:** Generate a UUID token before the callback. After `UpdateAsync` returns, verify acquisition by checking `result._session.token == token`. No closure mutation required.

---

### Defect 4 — `GetAsync` has no retry on transient failure (Medium)

**Root cause:** A single DataStore error immediately kicks the player and sets `loadFailed`.

**Impact:** Players are unnecessarily kicked during momentary DataStore instability.

**Location:** `PlayerDataManager.lua`, `loadPlayer()`.

**Fix:** Wrap the `UpdateAsync` load call in `withRetry` (3 attempts, 2 s / 4 s backoff). Only kick after all retries are exhausted.

---

## Revised Implementation Requirements

The following requirements must be satisfied in the revised `PlayerDataManager.lua`. They supersede b05aa20.

### R1 — Fencing token generation

- Generate using `HttpService:GenerateGUID(false)`.
- Generate **outside** the `UpdateAsync` callback, before the callback is constructed.
- Never generate or mutate external state inside the callback.
- Store in `sessionTokens[userId]` only after confirmed acquisition.
- One new token per `loadPlayer` invocation; `sessionTokens[userId]` is cleared on disconnect and confirmed session loss.

### R2 — Session acquisition

- Use `PlayerStore:UpdateAsync` on `TycoonPlayerData_v1` for both lock acquisition and data read.
- Callback must handle four cases without side effects:
  1. `current == nil` → new player (no prior record)
  2. `current` with live `_session` owned by another server → return nil (abort)
  3. `current` with no `_session`, expired `_session`, or our own `_session` → acquire
  4. Legacy record (existing game data, no `_session`) → acquire; preserve all existing fields
- Verify acquisition from the returned record: `result._session.token == token`.
- Retry up to 3 times on DataStore error; kick immediately on confirmed ownership by another server (not a transient error).

### R3 — Save ownership verification

- Guard: `loadFailed[userId]`, `loadedData[userId] == nil`, `sessionTokens[userId] == nil` → reject.
- Inside `UpdateAsync` callback: check `current._session.token == sessionTokens[userId]`.
- Match → write `deepCopy(loadedData[userId])` with `_session` restored from `current._session`.
- Mismatch → return nil; set `loadFailed[userId] = true`; kick player; do NOT retry.
- DataStore error → retry (up to 3 times).

### R4 — Refresh and release

- `refreshSession`: callback verifies token; on mismatch or nil result → confirmed session loss → `loadFailed = true`, kick.
- Track `lastSuccessfulRefresh[userId]`; if elapsed > LOCK_TTL without a successful refresh → treat as stolen.
- `releaseSession`: clear `sessionTokens[userId]` BEFORE the UpdateAsync call; callback verifies the captured token against the stored token; only marks `released = true` if they match.

### R5 — Disconnect and shutdown

- `PlayerRemoving`: save → release → clear `loadedData[userId]`, `sessionTokens[userId]`, `loadFailed[userId]`, `lastRefresh[userId]`.
- `BindToClose`: parallel saves with 25s deadline; each task calls save then release.
- `releaseSession` clears `sessionTokens` as its first step; a concurrent second release finds nil and returns without a DataStore call.

### R6 — `_session` isolation

- `loadedData[userId]` must NEVER contain `_session`.
- Strip `_session` from `result` before constructing `loadedData[userId]`.
- In `savePlayer` callback: restore `_session` from `current._session` (the DataStore record), not from memory.
- `_session` is never passed to `addCash`, `spendCash`, `getData`, or any game logic.

### R7 — DataStore name and schema

- DataStore name: `TycoonPlayerData_v1` (unchanged).
- Player key: `tostring(player.UserId)` (unchanged).
- Remove `TycoonSessionLocks_v1` entirely.
- All existing game data fields preserved; `_session` is a hidden sentinel that existing game code never encounters.

---

## TycoonManager Changes — Status: Complete

The five TycoonManager edits in b05aa20 are correct and do not require revision:

| Edit | Status |
|---|---|
| `WaitForChild("MapReady", 30)` initialization dependency | ✅ Correct |
| `plotsFolder` module-level reference | ✅ Correct |
| `getPlot` uses `plotsFolder` directly | ✅ Correct |
| `assignPlot` uses `plotsFolder` directly | ✅ Correct |
| `PlayerAdded` nil guard after `loadPlayer` | ✅ Correct |
| `PlayerRemoving` uses `plotsFolder` directly | ✅ Correct |

## MapBuilder Changes — Status: Complete

The `ServerStorage.MapReady` signal in b05aa20 is correct and does not require revision.

---

## What Was Not Changed (Unchanged from b05aa20)

- `TycoonPlayerData_v1` DataStore name
- Existing player data key format and schema
- `ShopHandler.lua`
- `UpgradeTable.lua`
- `HUD.client.lua`
- Rojo configuration files
- Gamepass IDs, Developer Product IDs, Group ID
- All gameplay systems
