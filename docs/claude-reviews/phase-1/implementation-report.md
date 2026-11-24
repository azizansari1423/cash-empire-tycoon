# Phase 1 Implementation Report — Cash Empire Tycoon

**Date:** 2026-11-24
**Branch:** `feature/phase-1-data-foundation`
**Commit:** `b05aa20e3bdb82a4b842e4d1131cd11a16b37170`
**Reviewer:** Claude Sonnet 4.6

---

## Scope

Phase 1 targeted the data persistence layer. No gameplay systems, UI, or monetization were modified.

**Files changed (3):**

| File | Type of change |
|---|---|
| `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` | Full rewrite |
| `RobloxTycoon/src/ServerScripts/TycoonManager.server.lua` | 5 targeted edits |
| `RobloxTycoon/src/ServerScripts/MapBuilder.server.lua` | 8-line addition |

**Files not changed:** `ShopHandler.lua`, `UpgradeTable.lua`, `HUD.client.lua`, all Rojo configs, all LocalScripts.

---

## Phase 1 Deliverables — Status

| Deliverable | Status | Notes |
|---|---|---|
| Safe player profile loading | ✅ Implemented | Three-case load distinction |
| Protection against saving profiles after failed loads | ✅ Implemented | `loadFailed[userId]` guard on all write paths |
| Session locking | ✅ Implemented (with defects — see below) | Custom `TycoonSessionLocks_v1` DataStore |
| Safe autosaving | ✅ Implemented | 60s loop, `loadFailed` guard inherited |
| Safe shutdown handling | ✅ Implemented | Parallel `BindToClose` with 25s deadline |
| Retry and failure handling | ⚠️ Partial | Save retries implemented; load retries absent |
| Safe handling of player disconnects | ✅ Implemented | `PlayerRemoving` saves, releases lock, clears tables |
| MapBuilder/TycoonManager initialization dependency | ✅ Implemented | `ServerStorage.MapReady` signal + `WaitForChild` |
| Removal of unused Heartbeat connection | ✅ Implemented | Dead stub at old line 100–102 removed |

---

## Critical Constraints Verification

| Constraint | Met? | Evidence |
|---|---|---|
| New player never confused with failed load | ✅ | Three-case if/elseif: `not loadOk` → kick; `raw ~= nil` → merge; `raw == nil` → new player |
| Failed load never initialized as new profile | ✅ | `loadFailed` set before any data assignment; function returns nil immediately |
| Unverified profile cannot earn, spend, or save | ✅ | `addCash`/`spendCash`/`savePlayer` all call `getData` or check `loadFailed` first |
| No `SetAsync` for profile persistence | ✅ | `SetAsync` replaced with `UpdateAsync` throughout |
| Session lock prevents concurrent server writes | ⚠️ | Lock acquired but ownership not re-verified during save (see Defect 1) |
| No silent discard after failed save | ✅ | `warn(...)` on every failure path in `withRetry` |
| `TycoonPlayerData_v1` name unchanged | ✅ | Verified in source |
| Existing player progress preserved | ✅ | Merge-on-load keeps all saved keys; DEFAULT_DATA fills new keys only |
| No push/publish/merge of implementation | ✅ | Implementation branch not pushed |

---

## Code Review Findings

A code review of commit `b05aa20` identified four defects. The implementation is **not ready for production** until these are resolved.

### Defect 1 — `savePlayer` does not verify session ownership at write time (Critical)

`savePlayer` calls `PlayerStore:UpdateAsync` with a callback that ignores `_current` and writes the in-memory profile unconditionally. The session lock is a separate DataStore key. There is no atomic check linking lock ownership to the write operation. A server whose lock has expired can still overwrite data belonging to a newer session.

**Location:** `PlayerDataManager.lua`, `savePlayer()` function.

### Defect 2 — `refreshLock` failure is undetected (High)

`refreshLock` is wrapped in a `pcall` but does not check whether the UpdateAsync callback actually refreshed the lock (the callback may return nil if the lock was stolen by another server). The server continues treating the lock as active even if it lost ownership.

**Location:** `PlayerDataManager.lua`, `refreshLock()` function and the refresh loop.

### Defect 3 — Closure mutation inside `UpdateAsync` callback (High)

`acquireLock` sets `acquired = true` as a side effect inside the UpdateAsync callback. Roblox may invoke this callback multiple times on retry. The final value of `acquired` depends on which invocation ran last, which is indeterminate when the DataStore layer retries a write.

**Location:** `PlayerDataManager.lua`, `acquireLock()` function.

### Defect 4 — `GetAsync` has no retry mechanism (Medium)

A single transient DataStore error immediately sets `loadFailed[userId]` and kicks the player. The Phase 1 requirement explicitly includes retry and failure handling. Transient Roblox DataStore errors (503, timeout) are common during peak load.

**Location:** `PlayerDataManager.lua`, `loadPlayer()` function.

---

## Architectural Concern

The two-DataStore design (`TycoonPlayerData_v1` for data, `TycoonSessionLocks_v1` for locks) cannot provide atomic lock-and-write operations. All four defects above are downstream consequences of this architecture. The recommended fix is a single-key design that embeds `_session` within `TycoonPlayerData_v1`, making every lock check and data write a single atomic `UpdateAsync` call. See `architecture.md` for the full analysis and recommended design.

---

## What Was Not Changed

The following are explicitly unchanged:

- `TycoonPlayerData_v1` DataStore name
- Existing player data key format and schema
- `ShopHandler.lua`
- `UpgradeTable.lua`
- `HUD.client.lua`
- Rojo configuration files (`default.project.json`, `*.project.json`)
- Gamepass IDs, Developer Product IDs, Group ID
- All gameplay systems (upgrades, prestige, promo codes, server boost)

---

## Next Step

Revise `PlayerDataManager.lua` using the single-key fencing token architecture described in `architecture.md`. No changes required to `TycoonManager.server.lua` or `MapBuilder.server.lua` — those Phase 1 fixes are correct and complete.
