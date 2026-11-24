# Phase 1 Test Results — Cash Empire Tycoon

**Date:** 2026-11-24
**Commit under review:** `b05aa20e3bdb82a4b842e4d1131cd11a16b37170`
**Environment:** Roblox Studio (local); no production test run performed

---

## Testing Constraints

Cash Empire Tycoon is a Roblox game. Its server scripts run inside the Roblox engine and interact with Roblox DataStore APIs. This imposes several constraints on automated testing:

- **No unit test framework:** Roblox does not provide a standard test runner for server scripts. Tools like TestEZ exist but are not configured in this project.
- **DataStore unavailable offline:** `DataStoreService` is unavailable outside Roblox Studio with a live place. Calls to `GetAsync`/`UpdateAsync` fail silently or error in pure offline environments.
- **Multi-server simulation requires Roblox:** Concurrent session lock behavior can only be tested using Roblox's Team Create or multiple Studio instances, neither of which is scripted here.
- **No CI pipeline:** The project has no GitHub Actions or equivalent workflow that runs tests.

The test results below are based on **static code analysis and logical verification** of the implementation against each acceptance criterion. No automated or runtime tests were executed.

---

## Acceptance Criteria Verification

### AC-1: New player distinguished from failed load

**Requirement:** A new player (key does not exist) must never be confused with a player whose DataStore load failed.

**Code path analysis:**
```lua
local loadOk, raw = pcall(function()
    return PlayerStore:GetAsync(userId)
end)

if not loadOk then
    -- DataStore threw → kick, set loadFailed, return nil
elseif raw ~= nil then
    -- Existing player → merge with DEFAULT_DATA
else
    -- New player → initialize from DEFAULT_DATA
end
```

The three cases are mutually exclusive. A `pcall` failure is detected before the nil check; a nil return is only reached when `pcall` succeeded. ✅

---

### AC-2: Failed load never initialized as new profile

**Requirement:** When GetAsync throws, the player must not receive a fresh DEFAULT_DATA profile.

**Code path analysis:**
When `loadOk == false`, the function sets `loadFailed[userId] = true`, releases the lock, kicks the player, and returns nil. The assignment `loadedData[userId] = data` is never reached. ✅

---

### AC-3: Unverified profile cannot earn, spend, or save

**Requirement:** A player whose data was not loaded successfully must not be able to modify game state.

**Code path analysis:**
- `addCash` calls `getData`, which returns `loadedData[userId]`. After a failed load, `loadedData[userId]` is nil — `addCash` returns without modifying anything. ✅
- `spendCash` has an explicit `if not data then return false end` guard. ✅
- `savePlayer` has an explicit `if loadFailed[userId] then warn; return false end` guard. ✅
- `TycoonManager.PlayerAdded` returns early with `if not data then return end` after `loadPlayer` returns nil. ✅

---

### AC-4: No SetAsync for profile persistence

**Requirement:** All writes to `TycoonPlayerData_v1` must use `UpdateAsync`.

**Grep result:** `SetAsync` does not appear anywhere in `PlayerDataManager.lua` as of commit b05aa20. The only DataStore write call is `PlayerStore:UpdateAsync(userId, function(_current) return data end)`. ✅

---

### AC-5: Session locking prevents concurrent server writes

**Requirement:** Two servers must not simultaneously modify the same player profile.

**Status:** ⚠️ **PARTIAL — Defect 1 applies**

Lock acquisition is correct: `acquireLock` uses `LockStore:UpdateAsync` to atomically claim the lock. Only one server can claim it.

However, the lock and the data are in separate DataStore keys. `savePlayer`'s `UpdateAsync` callback does not re-verify lock ownership at write time. If the lock has expired between acquisition and the next save, `savePlayer` will write without ownership. This violates the invariant.

See `architecture.md` — Defect 1 for the full scenario and recommended fix.

---

### AC-6: No silent discard after failed save

**Requirement:** A failed save must not be silently dropped.

**Code path analysis:**
`withRetry` emits a `warn(...)` on every failed attempt and a final `warn(...)` when all retries are exhausted. `savePlayer` additionally warns after `withRetry` returns false. No failure path completes silently. ✅

---

### AC-7: TycoonPlayerData_v1 name unchanged

**Requirement:** The DataStore name must remain `TycoonPlayerData_v1`.

**Grep result:** `DataStoreService:GetDataStore("TycoonPlayerData_v1")` appears exactly once in `PlayerDataManager.lua`. No other DataStore by that name is accessed elsewhere. ✅

---

### AC-8: Existing player progress preserved

**Requirement:** No existing player data may be lost or reset.

**Code path analysis:**
When `raw ~= nil` (existing player), the merge operation initializes from `deepCopy(DEFAULT_DATA)` and then overwrites all keys present in `raw`. Existing values take precedence over defaults. New default keys (added in future schema updates) are populated without touching existing ones. ✅

---

### AC-9: MapBuilder/TycoonManager initialization dependency

**Requirement:** TycoonManager must not access `Workspace.Plots` before MapBuilder has built all plots.

**Code path analysis:**
1. MapBuilder creates `plotsFolder` and all 4 plots, then creates `ServerStorage.MapReady`.
2. TycoonManager calls `ServerStorage:WaitForChild("MapReady", 30)` at module level — before `PlayerAdded` is connected.
3. After `MapReady` exists, `workspace:WaitForChild("Plots", 5)` resolves to the already-populated folder.
4. All three `FindFirstChild("Plots")` calls replaced with the module-level `plotsFolder` reference.

No player can join before `PlayerAdded` is connected; `PlayerAdded` is connected only after `plotsFolder` is initialized. ✅

---

### AC-10: Dead Heartbeat connection removed

**Requirement:** The unused `RunService.Heartbeat:Connect(function() end)` stub must be removed.

**Code path analysis:** The old lines 100–102 are absent from the rewritten file. The pattern `Heartbeat:Connect` does not appear in `PlayerDataManager.lua` as of b05aa20. ✅

---

## Known Issues

### Issue 1 — Non-atomic lock + write (Critical, Defect 1)

Two-DataStore architecture means `savePlayer` cannot verify session ownership at write time. A stale server can overwrite a live session's data. Full scenario and fix in `architecture.md`.

**Risk level:** Critical. Could cause data loss in multi-server environments.
**Mitigation until fixed:** Game is not live; lock TTL (60s) + refresh interval (20s) provide a window, but the gap is not closed by code.

### Issue 2 — `refreshLock` does not detect stolen sessions (High, Defect 2)

Callback returning nil is not distinguished from a successful refresh. Server may continue operating under a lock it no longer holds.

**Risk level:** High. Contributes to the stale-write scenario in Issue 1.

### Issue 3 — Callback side-effects on UpdateAsync retry (High, Defect 3)

`acquireLock` mutates `acquired` inside the UpdateAsync callback, which Roblox may invoke multiple times on write retry. Lock acquisition result is indeterminate on retry.

**Risk level:** High. Edge case; only triggered by DataStore write retry, which is uncommon but possible.

### Issue 4 — No retry on `GetAsync` failure (Medium, Defect 4)

A single transient DataStore error kicks the player and permanently blocks saves for that session. Players may be unnecessarily kicked during momentary DataStore instability.

**Risk level:** Medium. Affects player experience; does not corrupt data.

---

## Manual Test Plan (for Studio verification after fixes)

The following scenarios should be verified in Roblox Studio after the revised implementation is complete:

| Scenario | Steps | Expected result |
|---|---|---|
| New player first join | Delete DataStore key, join Studio | Player initialized with DEFAULT_DATA (Cash=0 etc.) |
| Existing player rejoin | Save some Cash, leave, rejoin | Cash value preserved across sessions |
| DataStore failure simulation | Disable network in Studio | Player receives kick message; `loadFailed` set; no phantom save |
| Session lock contention | Two Studio instances, same player (requires Team Create) | Second server kicks player |
| Stale lock expiry | Let lock expire (> 60s without refresh), rejoin | New session acquired without false kick |
| Autosave | Stay in game > 60s, verify no data loss | Cash persists through autosave cycle |
| Server shutdown | Use `BindToClose` test plugin | All players saved before shutdown completes |
| MapBuilder race | Join immediately at server start | No nil-reference error from TycoonManager |

---

## Summary

| Category | Result |
|---|---|
| New/failed load distinction | ✅ Pass |
| loadFailed guard on saves | ✅ Pass |
| SetAsync removal | ✅ Pass |
| Retry on save failure | ✅ Pass |
| Retry on load failure | ❌ Fail (Defect 4) |
| Session lock — acquisition | ✅ Pass |
| Session lock — write-time verification | ❌ Fail (Defect 1) |
| MapBuilder dependency | ✅ Pass |
| Dead Heartbeat removal | ✅ Pass |
| Data schema preserved | ✅ Pass |
| **Overall readiness** | **Not ready for production** |

The implementation is functionally correct for single-server scenarios. It is not safe for multi-server deployment until the single-key fencing token redesign described in `architecture.md` is implemented.
