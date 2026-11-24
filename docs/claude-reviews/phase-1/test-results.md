# Phase 1 Test Results — Cash Empire Tycoon (Revised)

**Date:** 2026-11-24 (revised from initial review)
**Commit under review:** `b05aa20e3bdb82a4b842e4d1131cd11a16b37170`
**Status:** Redesign pending; test plan covers both defects in b05aa20 and verification requirements for the revised design

---

## Testing Constraints

Cash Empire Tycoon is a Roblox game. Its server scripts run inside the Roblox engine and interact with Roblox DataStore APIs. This imposes several constraints on automated testing:

- No unit test framework is configured in this project. Tools such as TestEZ exist for Roblox but have not been set up here.
- DataStoreService is unavailable outside Roblox Studio with a live place. Calls to `GetAsync` and `UpdateAsync` fail in pure offline environments.
- Multi-server session lock contention can only be tested using multiple Studio instances (Team Create) or a live production server.
- No CI pipeline is configured; there are no automated test runs.

**All test results below are static code analysis and logic verification only. No runtime tests have been executed. This document does not claim runtime test passage.**

---

## Acceptance Criteria Verification (against b05aa20)

### AC-1 — New player distinguished from failed load

**Requirement:** A new player (key does not exist) must never be confused with a player whose DataStore load failed.

**Analysis:**
```
if not loadOk:
    → loadFailed = true; kick; return nil
elseif raw ~= nil:
    → existing player (merge)
else:
    → new player (DEFAULT_DATA)
```
The three cases are mutually exclusive by control flow. A `pcall` failure is detected before any nil check. ✅

---

### AC-2 — Failed load never initialized as new profile

**Requirement:** When GetAsync throws, the player must not receive a fresh DEFAULT_DATA profile.

**Analysis:** When `loadOk == false`, the function sets `loadFailed[userId] = true`, releases the lock, kicks the player, and returns nil before any `loadedData` assignment. ✅

---

### AC-3 — Unverified profile cannot earn, spend, or save

**Requirement:** A player whose data was not loaded successfully must not be able to modify game state.

**Analysis:**
- `addCash`: calls `getData` → returns `loadedData[userId]`; if nil → no-op. ✅
- `spendCash`: explicit `if not data then return false end` guard. ✅
- `savePlayer`: explicit `if loadFailed[userId] then return false end` guard. ✅
- `TycoonManager.PlayerAdded`: `if not data then return end` after `loadPlayer`. ✅

**Limitation in b05aa20:** `addCash` / `spendCash` are blocked only when `loadedData[userId] == nil`. If session ownership is lost mid-game (Defect 2), `loadedData` remains populated. The revised design sets `loadFailed[userId] = true` on session loss, which blocks saves but does NOT block `addCash` / `spendCash` (they check `getData`, not `loadFailed`). The revised design should also kick the player on session loss to stop further income accrual. ⚠️

---

### AC-4 — No SetAsync

**Requirement:** All writes to `TycoonPlayerData_v1` must use `UpdateAsync`.

**Analysis:** `SetAsync` does not appear in `PlayerDataManager.lua` as of b05aa20. The only write call is `PlayerStore:UpdateAsync`. ✅

---

### AC-5 — Session locking prevents concurrent server writes

**Status:** ⚠️ Fail — Defect 1

Lock acquisition is correct. However, `savePlayer` does not verify lock ownership at write time. A server whose lock has expired can overwrite a live session's data. Full scenario and fix in `architecture.md` §5.

---

### AC-6 — No silent discard after failed save

**Requirement:** A failed save must not be silently dropped.

**Analysis:** `withRetry` emits a warning on every failed attempt. `savePlayer` additionally warns after `withRetry` returns false. ✅

---

### AC-7 — `TycoonPlayerData_v1` name unchanged

**Analysis:** `DataStoreService:GetDataStore("TycoonPlayerData_v1")` appears exactly once in `PlayerDataManager.lua`. ✅

---

### AC-8 — Existing player progress preserved

**Analysis:** Merge-on-load: `deepCopy(DEFAULT_DATA)` overwritten with all saved fields. Existing values take precedence; new default keys filled without touching existing ones. ✅

---

### AC-9 — MapBuilder/TycoonManager initialization dependency

**Analysis:**
1. MapBuilder creates all 4 plots, then creates `ServerStorage.MapReady`.
2. TycoonManager calls `ServerStorage:WaitForChild("MapReady", 30)` at module level before `PlayerAdded` is connected.
3. `workspace:WaitForChild("Plots", 5)` resolves to the already-populated folder.
4. All `FindFirstChild("Plots")` calls replaced with module-level `plotsFolder`.
✅

---

### AC-10 — Dead Heartbeat connection removed

**Analysis:** `RunService.Heartbeat:Connect` does not appear in `PlayerDataManager.lua` as of b05aa20. ✅

---

## Concurrency Scenarios

The following scenarios test the session lock design. None have been executed at runtime. They are logic traces against the **revised design** (single-key fencing token) described in `architecture.md`.

### Scenario C-1 — Two servers acquire session simultaneously

```
Server A: generates token T_A; UpdateAsync starts
Server B: generates token T_B; UpdateAsync starts
DataStore serializes: Server A's callback runs first
  current = nil (new player or no active session)
  → no live lock → write { _session: {token=T_A, ...} }
Server B's callback runs second:
  current = { _session: {jobId=A, token=T_A, since=now, released=false} }
  jobId_A ≠ JOB_ID_B, not released, not stale → live lock → return nil
Server B's UpdateAsync returns nil (or existing value with T_A)
Server B: result._session.token == T_B? No → acquisition failed → kick player
```

Expected: Server A acquires; Server B kicks the player. Data safe. ✅

---

### Scenario C-2 — Stale session takeover (Server A lock expires)

```
Server A: holds session, token T_A, since = T_0
Server A: refresh fails (3× DataStore errors); no successful refresh for > LOCK_TTL
Server A: loadFailed[userId] = true; kicks player (via lock-expiry logic)
Server B: player rejoins
  UpdateAsync: current._session.since is old (T_0 + LOCK_TTL+ elapsed)
  → stale lock → Case B → acquire with token T_B
Server A (if any in-flight save fires): callback reads current._session.token == T_B ≠ T_A → abort
```

Expected: Server B acquires safely. Server A's save is blocked by token mismatch. ✅

**Note:** This scenario requires the refresh-failure tracking (`lastSuccessfulRefresh[userId]`) described in `architecture.md` §6.2. It is NOT present in b05aa20.

---

### Scenario C-3 — Stale server save after session stolen

```
Server A: holds session, token T_A
Server A: lock refresh fails once → (no kick yet; not past LOCK_TTL)
Server B: detects stale lock after TTL; acquires with token T_B
Server A: 60-second autosave fires
  savePlayer callback: current._session.token == T_B ≠ T_A → sessionVerified = false → return nil
  pcall succeeds; sessionVerified = false → confirmed session loss
  → loadFailed[userId] = true; kick player; return false
```

Expected: Server A's save is aborted. Server B's data untouched. ✅

---

### Scenario C-4 — Callback retry on write ack loss

```
Server A: generateToken T_A; UpdateAsync starts
  Callback call 1: current = nil → acquire → returns { _session: {token=T_A}, ... }
  Write goes to DataStore but ack is lost
  Callback call 2 (retry): current = { _session: {token=T_A}, ... } (already written)
    → current._session.jobId == JOB_ID, same server → Case B (our own lock) → re-acquire with same token
    → returns same record
  UpdateAsync returns
Server A: result._session.token == T_A → acquisition confirmed
```

Expected: Callback retry is idempotent. Acquisition result is correct. ✅

---

## Refresh Failure Scenarios

### Scenario R-1 — Single transient refresh error

```
Refresh loop fires for userId
refreshSession: pcall(UpdateAsync) → DataStore error
No result. lastSuccessfulRefresh[userId] is recent (< LOCK_TTL ago)
→ log warning; no kick; continue
Next refresh fires 20s later → succeeds → lastSuccessfulRefresh updated
```

Expected: One transient failure does not trigger a kick. ✅

---

### Scenario R-2 — Repeated refresh failures leading to lock expiry

```
3 consecutive refresh failures (network outage)
os.time() - lastSuccessfulRefresh[userId] > LOCK_TTL (60s)
→ The lock has certainly expired
→ loadFailed[userId] = true; kick player
```

Expected: Player kicked before another server can steal and corrupt data. ✅

**Note:** Exact threshold (number of failures vs elapsed time) must be decided at implementation; architecture.md §6.2 recommends time-based (`> LOCK_TTL since last success`) over count-based.

---

### Scenario R-3 — Session stolen mid-game

```
Player on Server A. Server A's lock expires.
Server B: takes over (token T_B in DataStore).
Server A: refresh fires:
  callback: current._session.token == T_B ≠ T_A → return nil
  pcall succeeds; returned record token ≠ T_A → confirmed session loss
  → loadFailed[userId] = true; kick player
Server A: in-game income tick fires: addCash → getData → loadedData[userId] still set
```

**Gap:** `addCash` checks `getData`, not `loadFailed`. After session loss, in-memory data is stale but `addCash` still modifies it. The only practical mitigation is the kick (player is ejected and income ticks stop). The kick must fire promptly.

**Mitigation in revised design:** Kick the player immediately on confirmed session loss in `refreshSession`. This stops all further in-game state modification.

---

## Duplicate Save Prevention Scenarios

### Scenario D-1 — `PlayerRemoving` and `BindToClose` both save the same player

```
Server shutdown initiated.
PlayerRemoving fires for Player X (concurrent with BindToClose):

Thread A (PlayerRemoving):
  savePlayer(X) → UpdateAsync starts → yields
Thread B (BindToClose task for X):
  savePlayer(X) → loadedData[X] is set → UpdateAsync starts → yields

Thread A: callback: current._session.token == T_A == sessionTokens[X] → write → success
Thread B: callback: current._session.token == T_A == sessionTokens[X] → write same data → success (idempotent)

Thread A: releaseSession(X) → captures T_A; clears sessionTokens[X] = nil; UpdateAsync → marks released
Thread B: releaseSession(X) → reads sessionTokens[X] = nil → captures nil → callback: token ≠ nil → return nil → no-op
```

Expected: One release written. Two saves written (idempotent — same data). ✅

---

### Scenario D-2 — `PlayerRemoving` clears `loadedData` before `BindToClose` task saves

```
Thread A (PlayerRemoving):
  savePlayer → succeeds
  releaseSession → succeeds
  loadedData[X] = nil
Thread B (BindToClose task for X):
  savePlayer(X): loadedData[X] == nil → return false immediately
```

Expected: No second DataStore write. ✅

---

## Shutdown Race Scenarios

### Scenario S-1 — Shutdown deadline reached with in-flight save

```
BindToClose: 25s deadline starts
Player X: save spawned; withRetry is on attempt 2 (waiting 4s backoff)
Deadline reached: savingCount > 0
warn("[DataManager] BindToClose: shutdown with 1 unsaved player(s)")
Roblox terminates server process
```

Expected: Warning logged. Data may be lost for Player X. This is a known and accepted platform-level limitation. The in-flight `UpdateAsync` may or may not complete depending on whether Roblox's HTTP layer flushes before process termination.

---

### Scenario S-2 — All players saved before deadline

```
4 players online; all spawned as concurrent save tasks
4× UpdateAsync in parallel; all complete within 5s
savingCount = 0 before deadline
BindToClose completes normally
```

Expected: All players saved. No warnings. ✅

---

## Manual Test Plan (for Studio after redesign implementation)

The following scenarios should be verified in Roblox Studio after the revised `PlayerDataManager.lua` is implemented. None of these tests have been run yet. This plan is for the revised design only.

| ID | Scenario | Setup | Expected Result |
|---|---|---|---|
| T-1 | New player first join | Delete DataStore key; join Studio | Cash=0, TotalEarned=0, all DEFAULT_DATA |
| T-2 | Existing player rejoin | Earn cash; leave; rejoin | Cash value preserved |
| T-3 | DataStore error on load (all retries) | Simulate via throttling plugin | Player kicked; `loadFailed = true`; no phantom save |
| T-4 | DataStore error on load (1 transient) | Simulate 1 failure then succeed | Player loads normally after retry |
| T-5 | Legacy record first load | Use old-format DataStore entry | All existing fields preserved; `_session` added |
| T-6 | Session lock — concurrent join | Two Studio instances, same account | Second server kicks player |
| T-7 | Stale lock expiry | Let lock expire (60s+), rejoin | New session acquired without false kick |
| T-8 | Session loss during play | Manually overwrite lock in DataStore | Player kicked on next refresh; save aborted |
| T-9 | Autosave cycle | Stay in game >60s | Cash persists; no data loss |
| T-10 | BindToClose | Use Roblox shutdown simulation plugin | All players saved before process exit |
| T-11 | PlayerRemoving + BindToClose race | Disconnect at same time as shutdown | One save and one release per player; no duplicate releases |
| T-12 | GUID uniqueness in Studio | Join repeatedly in same session | Different tokens per join; `sessionTokens` updated correctly |
| T-13 | Session ownership loss mid-game | Steal lock externally during active session | Player kicked; in-game income stops; no stale save |
| T-14 | `_session` not exposed to game | Log `PlayerDataManager.getData(player)` | No `_session` key in output |
| T-15 | MapBuilder race | Join immediately at server start | No nil-reference errors in output |

---

## Summary

| Category | b05aa20 Status | Revised design required? |
|---|---|---|
| New/failed load distinction | ✅ Pass | No |
| loadFailed guard on saves | ✅ Pass | Extend: also covers session loss |
| SetAsync removal | ✅ Pass | No |
| Save retries | ✅ Pass | No |
| Load retries | ❌ Fail (Defect 4) | Yes — withRetry on UpdateAsync |
| Session lock — acquisition | ⚠️ Unsafe (Defect 3) | Yes — GUID + return-value verification |
| Session lock — save-time verification | ❌ Fail (Defect 1) | Yes — token check in callback |
| Refresh failure detection | ❌ Fail (Defect 2) | Yes — return-value + elapsed time check |
| Duplicate save safety | ⚠️ Idempotent but not controlled | Acceptable; documented |
| Shutdown race safety | ⚠️ Partial | Improved by token check |
| _session isolation | N/A (not in b05aa20) | Yes — strip before returning |
| MapBuilder dependency | ✅ Pass | No |
| Heartbeat stub removal | ✅ Pass | No |
| **Overall readiness** | **Not production-ready** | **Revision required before implementation** |
