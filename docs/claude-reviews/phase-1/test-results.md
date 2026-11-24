# Phase 1 Test Results — Cash Empire Tycoon (Revision 3)

**Date:** 2026-11-24
**Commit under review:** b05aa20 (`feature/phase-1-data-foundation`)
**Review revision:** 5
**Status:** Test plan revised — runtime tests not yet executed

> **Note:** All test results in this document are design-level analysis. No runtime tests have been executed. Test scenarios marked PASS/FAIL reflect whether the revised design is expected to handle them correctly, not observed runtime behaviour.

---

## Acceptance Criteria Verification

| Criterion | Expected result with revised design | Requires runtime verification |
|---|---|---|
| New player gets DEFAULT_DATA | Load path: no matching DataStore record → `rawData` empty → data = deepCopy(DEFAULT_DATA) | Yes |
| Existing player data loaded correctly | Returned record fields merged over DEFAULT_DATA; `_session` stripped | Yes |
| Load failure does not initialize default profile | `ok=false` or `result==nil` after all retries → `playerState="failed"`, kick; `loadedData` not populated | Yes |
| Session lock prevents duplicate writes | Save callback: `current._session.token ~= token` → return nil → no write | Yes |
| Stale lock (TTL expired) allows new server to acquire | Acquisition callback: `(now - sess.since) >= LOCK_TTL` → available for acquisition | Yes |
| `addCash`/`spendCash` blocked after session loss | `invalidated[userId]=true` → `getData` returns nil → operations return false/nil | Yes |
| `releaseSession` called twice is a no-op | State "releasing"/"released" → `releaseSession` returns without action | Yes |
| BindToClose completes within 25 s deadline | Parallel saves with `task.wait(0.1)` poll; deadline enforced | Yes |
| Legacy records (no `_session`) load correctly | Acquisition callback: `current._session == nil` → treated as available; all existing fields preserved | Yes |
| `_session` never in `getData` return value | `loadedData[userId]` populated without `_session` at load time; `getData` returns that table | Yes |

---

## Scenario Tests

### Callback Retry After Ownership Change (NEW — Issue 1)

**Scenario CR-1: Save callback retried after session theft**

```
Setup:    Server A holds session, token T_A. Server B acquires session (token T_B in DataStore).
          Server A's UpdateAsync save yields during write; Roblox retries callback.
Step 1:   Callback call 1: current._session.token == T_A → match → returns newRecord
Step 2:   Write ack lost (partition). DataStore has T_A record from call 1.
Step 3:   Server B: loadPlayer → UpdateAsync → sees T_A, TTL not met → waits.
          (Assume T_A TTL expires; Server B acquires with T_B.)
Step 4:   Roblox retries Server A callback: current._session.token == T_B ≠ T_A → return nil
Step 5:   UpdateAsync returns nil (ok=true, result=nil).
Step 6:   Outer code: result == nil → confirmedSessionLoss = true (set outside callback) → break
Step 7:   playerState = "invalidated"; invalidated[userId] = true; player kicked.
Expected: Server A's stale data is NOT written. Server B's session intact. DESIGN: PASS
```

**Scenario CR-2: Acquisition callback retried after own write (idempotent)**

```
Setup:    Server A: loadPlayer, token T_A. First callback call writes T_A to DataStore. Ack lost.
Step 1:   Roblox retries acquisition callback.
Step 2:   current._session.token == T_A == token (ourRetry = true) → callback re-writes same record.
Step 3:   UpdateAsync returns record with T_A.
Step 4:   Verification: result._session.token == T_A == token → acquisition confirmed.
Expected: Idempotent retry succeeds. Data loaded normally. DESIGN: PASS
```

**Scenario CR-3: Acquisition callback retried — another server intervened between calls**

```
Setup:    Server A: loadPlayer, token T_A. Call 1: sess absent → callback writes T_A. Ack lost.
          Server B: loadPlayer, token T_B. UpdateAsync runs; sees T_A (live); T_A TTL not expired.
          Server B callback: sess.jobId ≠ JOB_ID_B → Server B aborts → Server B kicks its player.
Step 1:   Roblox retries Server A callback: current._session.token == T_A == token → ourRetry = true
Step 2:   re-writes same record; UpdateAsync returns T_A record.
Step 3:   Server A: verification passes; session acquired.
Expected: Server A retains session. Server B correctly aborted. DESIGN: PASS
```

---

### Duplicate Same-Server Load (NEW — Issue 2)

**Scenario DS-1: Two concurrent loadPlayer calls for the same player**

```
Setup:    Server: playerState[X] = nil.
Thread 1: loadPlayer(X) → token T_A generated → playerState[X] = "loading" → UpdateAsync yields
Thread 2: loadPlayer(X) → playerState[X] == "loading" → warn + return nil immediately
Step 1:   Thread 1 UpdateAsync completes; session acquired with T_A.
Step 2:   playerState[X] = "active"; sessionTokens[X] = T_A.
Step 3:   Thread 2 returns nil — no session acquired, no data loaded, no token stored.
Expected: Exactly one session acquired. Thread 2 is a safe no-op. DESIGN: PASS
```

**Scenario DS-2: Live same-server session with different token is blocked**

```
Setup:    DataStore has {_session: {jobId: JOB_ID, token: T_OLD, since: 10s ago}}.
          LOCK_TTL = 60s. New loadPlayer: token T_NEW generated.
Step 1:   Callback: sess.since = 10s ago; (now - sess.since) = 10 < 60 → session live.
Step 2:   sess.token == T_OLD ≠ T_NEW → live session, token mismatch → return nil.
Step 3:   UpdateAsync returns nil (or existing record with T_OLD).
          ok=true, (result==nil OR result._session.token==T_OLD≠T_NEW) → confirmed failure → kick.
Expected: Player kicked. DESIGN: PASS
Note:     This is the same-server guard from §5.1 (concurrent load) acting as defence-in-depth.
          Under normal operation the concurrent-load guard would prevent two loadPlayer calls
          from reaching the callback simultaneously. This covers Studio restarts within LOCK_TTL.
```

**Scenario DS-3: Expired same-server session (any jobId) is available for acquisition**

```
Setup:    DataStore has {_session: {jobId: JOB_ID, token: T_OLD, since: 100s ago}}.
          LOCK_TTL = 60s. New loadPlayer: token T_NEW.
Step 1:   Callback: (now - sess.since) = 100 >= 60 → session expired → available.
          (jobId check is NOT performed; TTL is the only gate.)
Step 2:   Fall through to write: newRecord._session = {T_NEW, now, released:false}.
Step 3:   UpdateAsync returns newRecord; result._session.token == T_NEW → acquisition confirmed.
Expected: Session acquired normally. DESIGN: PASS
Note:     Consistent with §5.3 Revision 4. The same-server guard in DS-2 applies only when
          TTL is live. An expired session is reclaimed regardless of jobId.
```

---

### Mutation After Ownership Loss (NEW — Issue 3)

**Scenario ML-1: `addCash` called after session theft detected during refresh**

```
Setup:    Server A holds session. 3 refresh failures; os.time()-lastRefresh[X] > LOCK_TTL.
Step 1:   refreshSession detects expiry; invalidated[X] = true; playerState[X] = "invalidated".
          player:Kick() called (kick delivery takes a few yields).
Step 2:   Income tick fires between invalidation and kick delivery:
          addCash(X, 100) → getData(X) → invalidated[X]==true → return nil
          addCash: data == nil → early return; no mutation. PASS
Step 3:   spendCash(X, 50) → getData(X) → nil → return false. PASS
Step 4:   Player is kicked. Income ticks stop.
Expected: No mutation to stale in-memory profile after ownership loss. DESIGN: PASS
```

**Scenario ML-2: `addCash` called after `loadPlayer` returned nil (failed load)**

```
Setup:    loadPlayer fails all retries; playerState[X]="failed"; invalidated[X]=true; loadedData[X]=nil.
          Game code calls addCash before kick is delivered.
Step 1:   addCash(X, 100) → getData(X) → invalidated[X]=true → return nil → addCash: no-op. PASS
Expected: No mutation. DESIGN: PASS
```

**Scenario ML-3: `getData` called in state "releasing" (valid — PlayerRemoving path)**

```
Setup:    PlayerRemoving fires; releaseSession transitions to "releasing".
          Some code calls getData during release (e.g., a final balance check).
Step 1:   getData: playerState[X] == "releasing" → allowed → returns loadedData[X].
Expected: getData returns valid data during graceful release path. DESIGN: PASS
```

---

### Save Snapshot Correctness (NEW — Revision 4, D-6)

**Scenario SS-1: releaseSession clears loadedData while save callback is mid-retry**

```
Setup:    Server A: savePlayer starts for Player X.
          token=T_A, snapshot=deepCopy(loadedData[X]) captured before UpdateAsync.
          loadedData[X] = {Cash:500}.
Step 1:   savePlayer UpdateAsync yields (callback in progress).
Step 2:   releaseSession runs: loadedData[X] = nil (cleared in PlayerRemoving cleanup).
Step 3:   Roblox retries save callback (ack lost on first attempt).
          Callback reads: snapshot (local variable, deepCopy) → {Cash:500} ✓
                          token (local variable) → T_A ✓
          Neither reads loadedData[X] (which is now nil).
Step 4:   current._session.token == T_A → callback writes {Cash:500, _session:{T_A}}.
Step 5:   result._session.token == T_A → save confirmed ✅
Expected: Correct data written even after loadedData cleared. DESIGN: PASS

Broken (Revision 3) behaviour at Step 3:
          Callback reads: loadedData[X] → nil → deepCopy(nil) → error or empty record ← WRONG
```

**Scenario SS-2: Two overlapping saves with different snapshots — ordering**

```
Setup:    Autosave (time T0) captures snapshot_T0 = {Cash:100}.
          addCash(50) runs: loadedData[X].Cash = 150.
          PlayerRemoving save (time T1) captures snapshot_T1 = {Cash:150}.
          Both UpdateAsync calls are in-flight.
Step 1:   releaseSession waits for inFlightSaves[X] == 2 → loops.
Step 2:   DataStore serializes: autosave (snapshot_T0) commits first.
          DataStore now has {Cash:100, _session:{T_A}}.
Step 3:   PlayerRemoving save (snapshot_T1) callback: T_A matches → writes {Cash:150, _session:{T_A}}.
          inFlightSaves[X] = 0 → releaseSession wait exits.
Step 4:   release UpdateAsync commits → {Cash:150, _session:{T_A, released:true}}.
Final DataStore state: {Cash:150, ...} ✅ (most recent snapshot committed last)
Note:     This ordering holds because releaseSession waited for both saves.
          If DataStore had serialized PlayerRemoving save first (Step 2 reversed),
          the autosave would commit {Cash:100} last — data 50 coins stale.
          This is Risk 6 in §15 of architecture.md.
Expected: At worst one autosave interval of staleness (60s earnings).
          Release always comes after both saves. DESIGN: PASS (with Risk 6 noted)
```

### Refresh Non-Nil Wrong-Token Result (NEW — Revision 4, D-8)

**Scenario RV-1: refreshSession — UpdateAsync returns existing record with wrong token**

```
Setup:    Server A holds session, token T_A. Server B acquires session (T_B in DataStore).
          Server A refresh callback: current._session.token == T_B ≠ T_A → callback returns nil.
Step 1:   UpdateAsync returns (Behaviour B) current record {_session:{T_B, ...}}.
          ok=true, result != nil, result._session.token == T_B ≠ T_A.
Step 2:   Revision 3 code: only checked `if ok and result == nil` → did NOT reach ownership-loss path.
          Server A believed refresh succeeded ← WRONG (Revision 3 defect).
Step 3:   Revision 4 code: else branch catches `result._session.token ~= T_A` → ownership loss path.
          invalidated[X]=true; player kicked. ✅
Expected: Revision 4 correctly handles both Behaviour A (nil) and Behaviour B (wrong-token non-nil).
DESIGN: PASS (Revision 4)
```

**Scenario RV-2: refreshSession — UpdateAsync returns nil (Behaviour A)**

```
Step 1:   Server B acquires; Server A refresh callback returns nil.
          UpdateAsync returns nil.
Step 2:   ok=true, result==nil → else branch → ownership loss → invalidated; kick ✅
Expected: Same outcome regardless of nil vs non-nil behaviour. DESIGN: PASS
```

### In-Flight Save Wait (NEW — Revision 4, D-9)

**Scenario IW-1: Revision 4 drain-timeout proceeded with release — accurate risk description**

(This corrects the IW-1 scenario from Revision 4, which incorrectly claimed the late save would re-write `released=false`.)

```
Revision 4 actual behaviour when drain timeout is exceeded and release proceeds:
Step 1:   Autosave in-flight (inFlightSaves[X]=1). Drain deadline exceeded.
Step 2:   releaseSession proceeds: release UpdateAsync → {data_at_release, _session:{T_A, released:true}}.
Step 3:   Autosave eventually completes. Callback receives current = {data_at_release, _session:{T_A, released:true}}.
          current._session.token == T_A → match.
          newRecord = deepCopy(autosave_snapshot); newRecord._session = current._session.
          → newRecord._session.released = true  (copied from current, NOT overwritten to false)
          → writes {autosave_snapshot, _session:{T_A, released:true}}

Actual risks in Revision 4:
- released=true IS preserved: the late save does NOT re-open the session. ✓
- Stale snapshot: autosave_snapshot may be older than data_at_release, overwriting newer values.
- Delayed acquisition by other servers: while autosave is running, any server calling
  loadPlayer sees `current._session.token == T_A`, released=true (from step 2). It treats
  the session as released and acquires normally. But then autosave commits step 3, overwriting
  with autosave_snapshot. The other server's subsequent saves start from autosave_snapshot
  (the stale data). This is data loss, not a session-opening violation.

Revision 5 fix: When drain deadline exceeded, do NOT proceed with release (TTL path).
Autosave eventually commits its snapshot. No other server can acquire until TTL expires.
No stale snapshot race; no data written after release. DESIGN: PASS (Revision 5)
```

**Scenario IW-2: disconnectPlayer — drain deadline exceeded (TTL path)**

```
Setup:    Autosave in flight (inFlightSaves[X]=1). DataStore stalled.
Step 1:   disconnectPlayer: drain wait; DRAIN_DEADLINE (5s) exceeded; inFlightSaves[X] still 1.
Step 2:   state→"abandoned"; activeLocks[X]=nil (already set); sessionTokens[X]=nil (already set).
          loadedData[X]=nil; lastRefresh[X]=nil; shuttingDown[X]=nil.
          inFlightSaves[X] NOT cleared (autosave owns its slot).
Step 3:   disconnectPlayer returns. No disconnect save. No release UpdateAsync.
Step 4:   Autosave eventually completes: inFlightSaves[X] decremented → 0.
          Callback: T_A matches DataStore → data written ✅
Step 5:   No refresh fires (activeLocks cleared at step 1). After LOCK_TTL seconds
          from last refresh, session expires. Another server acquires normally.
Expected: Session expires by TTL. Autosave snapshot preserved. No cleanup race. DESIGN: PASS
```

**Scenario IW-3: disconnectPlayer — save deadline exceeded (TTL path)**

```
Setup:    Drain passes (inFlightSaves[X]=0). disconnectPlayer starts disconnect save.
          savePlayer(X): inFlightSaves[X]=1; UpdateAsync stalls.
Step 1:   SAVE_DEADLINE (~12s) exceeded; inFlightSaves[X] still 1.
Step 2:   state→"abandoned"; inFlightSaves[X]=nil (deliberate give-up — warning issued).
          loadedData[X]=nil; shuttingDown[X]=nil. No release UpdateAsync.
Step 3:   Stuck UpdateAsync eventually resolves (or DataStore rejects it).
          Callback: inFlightSaves decrement now operates on nil → potential nil error.
          This is the acknowledged risk of the give-up path.
Step 4:   Session expires by TTL.
Expected: Degraded path; potential nil-decrement after give-up. Requires implementation
          care (e.g., nil-safe decrement: inFlightSaves[X] = math.max(0, (inFlightSaves[X] or 1)-1)).
DESIGN: PASS with implementation note (nil-safe decrement required).
```

### Single-Owner Disconnect and Save Serialization (NEW — Revision 5, D-12)

**Scenario SO-1: PlayerRemoving fires first; BindToClose observes ownership**

```
Setup:    Server shutdown: PlayerRemoving fires for Player X.
Step 1:   PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle starts.
Step 2:   BindToClose fires. Iterates Players; Player X is in list.
          disconnectPlayer(X) → shuttingDown[X]==true → return immediately ✅
Step 3:   PlayerRemoving lifecycle: drain→save→release completes.
Expected: Exactly one save, one release. No competing saves. DESIGN: PASS
```

**Scenario SO-2: BindToClose fires first; PlayerRemoving observes ownership**

```
Setup:    BindToClose fires before PlayerRemoving has called disconnectPlayer.
Step 1:   BindToClose: task.spawn → disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle.
Step 2:   PlayerRemoving fires.
          disconnectPlayer(X) → shuttingDown[X]==true → return immediately ✅
Step 3:   BindToClose lifecycle: drain→save→release completes.
Expected: Exactly one save, one release. No competing saves. DESIGN: PASS
```

**Scenario SO-3: PlayerRemoving fires first but BindToClose reached the spawn point before shuttingDown was set**

```
Setup:    Race: BindToClose task.spawn fires at the exact moment PlayerRemoving starts disconnectPlayer.
          Roblox cooperative scheduler: only one coroutine runs at a time between yields.
Step 1:   PlayerRemoving (runs first): disconnectPlayer(X) → sets shuttingDown[X]=true; yields at drain wait.
Step 2:   BindToClose spawn resumes: disconnectPlayer(X) → shuttingDown[X]==true → return immediately ✅
          (Cooperative scheduler means shuttingDown is set before any yield, so no actual race.)
Expected: shuttingDown assignment is atomic at coroutine boundaries. No race. DESIGN: PASS
```

**Scenario SO-4: Serialised saves — autosave drains before disconnect save (Revision 5)**

```
Setup:    Autosave captures snapshot_T0={Cash:100}. addCash(50) runs: loadedData[X].Cash=150.
          Autosave UpdateAsync yields. PlayerRemoving fires.
Step 1:   disconnectPlayer(X): drain wait; inFlightSaves[X]==1 > 0 → loops.
Step 2:   Autosave UpdateAsync completes; inFlightSaves[X]=0.
          DataStore: {Cash:100, _session:{T_A}}.
Step 3:   Drain passes. disconnectPlayer takes disconnect snapshot_T1=deepCopy(loadedData[X])={Cash:150}.
Step 4:   savePlayer(X) starts; inFlightSaves[X]=1; UpdateAsync with snapshot_T1.
Step 5:   Disconnect save completes: DataStore={Cash:150, _session:{T_A}} ✅
          inFlightSaves[X]=0.
Step 6:   releaseSession → released=true. DataStore={Cash:150, _session:{T_A, released:true}} ✅
Expected: Final DataStore value is snapshot_T1={Cash:150}, the more recent snapshot.
          No two saves ever in-flight simultaneously. DESIGN: PASS

Contrast with Revision 4 (D-12):
Step 1:   PlayerRemoving savePlayer + BindToClose savePlayer both start; inFlightSaves[X]=2.
Step 3:   DataStore serializes: autosave (Cash:100) runs last → overwrites disconnect (Cash:150).
          Final DataStore: {Cash:100} ← DATA STALE (Revision 4 unfixed)
```

### Save/Release Concurrency (now handled by disconnectPlayer)

**Scenario SR-1: Autosave in-flight when PlayerRemoving fires (updated for Revision 5)**

```
Setup:    Autosave in flight (inFlightSaves[X]=1; snapshot_T0 captured). PlayerRemoving fires.
Step 1:   disconnectPlayer(X): shuttingDown[X]=true; sessionTokens[X]=nil; drain wait.
Step 2:   Autosave completes; inFlightSaves[X]=0 → drain passes.
Step 3:   Disconnect save: snapshot_T1 captured (most recent); inFlightSaves[X]=1; UpdateAsync.
Step 4:   Disconnect save completes; inFlightSaves[X]=0.
Step 5:   releaseSession → released=true ✅.
Expected: One save at a time. Final state = snapshot_T1 ≥ snapshot_T0. DESIGN: PASS
```

**Scenario SR-2: New save attempt after `sessionTokens` cleared**

```
Setup:    releaseSession in progress; sessionTokens[X] = nil.
          A second autosave fires.
Step 1:   savePlayer: playerState[X] == "releasing" → check passes (releasing allows saves).
Step 2:   local token = sessionTokens[X] → nil.
Step 3:   if token == nil: return false immediately. PASS
Expected: Second save rejected before any DataStore call. DESIGN: PASS
```

**Scenario SR-3: Both PlayerRemoving and BindToClose call releaseSession**

```
Setup:    Server shutdown: PlayerRemoving and BindToClose both fire for Player X.
Step 1:   Thread A (PlayerRemoving): releaseSession → state "active" → "releasing"; token T_A captured.
Step 2:   Thread B (BindToClose): releaseSession → state == "releasing" → no-op; returns. PASS
Step 3:   Thread A release UpdateAsync → state → "released". PASS
Expected: Exactly one release written. No duplicate state transition. DESIGN: PASS
```

**Scenario SR-4: Release UpdateAsync fails all retries**

```
Setup:    PlayerRemoving fires; releaseSession starts; all 3 release UpdateAsync attempts fail.
Step 1:   released = false after loop.
Step 2:   warn("Release failed for userId=X. Lock will expire after 60s.").
Step 3:   playerState[X] = "released" (unconditional).
Step 4:   activeLocks[X] was cleared in releaseSession — refresh loop no longer refreshes X's session.
Step 5:   DataStore: X's session TTL counts down from last successful refresh.
Step 6:   After LOCK_TTL=60s, session expires → available for acquisition on rejoin.
Expected: Session expires via TTL. No permanent lock. DESIGN: PASS (with 60s delay before rejoin)
```

**Scenario SR-5: `savePlayer` called after state is "released"**

```
Setup:    PlayerRemoving has completed; state = "released"; loadedData[X] = nil.
          BindToClose fires and tries savePlayer(X).
Step 1:   savePlayer: playerState[X] == "released" → not "active"/"releasing" → return false. PASS
Expected: No DataStore call. DESIGN: PASS
```

---

### Concurrency Scenarios (from previous revision, updated)

**Scenario C-1: Normal acquire → save → release**

```
Expected: acquisition confirmed by token match; save confirmed by token match; release marks released=true.
State transitions: nil→loading→active→releasing→released. DESIGN: PASS
```

**Scenario C-2: Two servers attempt simultaneous acquisition**

```
Server A: token T_A. Server B: token T_B.
DataStore serializes. Server A wins: writes T_A. Server B callback: T_A ≠ T_B, TTL live → return nil.
Server B: result==nil → kick. Server A: result._session.token==T_A → acquired.
DESIGN: PASS
```

**Scenario C-3: Server B acquires after Server A disconnects (TTL expiry)**

```
Server A disconnects without releasing. After 60s, T_A's `since` is > LOCK_TTL.
Server B: acquisition callback: (now - sess.since) >= LOCK_TTL → available → writes T_B.
Server B: result._session.token == T_B → acquired.
DESIGN: PASS
```

**Scenario C-4: Server A refresh races with Server B acquisition**

```
Server A: refreshSession UpdateAsync yields. Server B: loadPlayer UpdateAsync yields.
Case 1: Server A refresh wins. Server B sees T_A with fresh `since` → TTL live → Server B aborts.
Case 2: Server B acquires first (T_B in DataStore). Server A refresh callback: T_A ≠ T_B → nil.
        Server A: refresh returns nil → invalidated[X]=true → Server A kicks its player.
DESIGN: PASS (both orderings handled)
```

---

### Refresh Failure Scenarios

**Scenario R-1: Single transient refresh failure**

```
Refresh attempt fails (DataStore error). os.time()-lastRefresh[X] = 15s < LOCK_TTL(60s).
→ log warning; no invalidation. Next scheduled refresh in 20s will retry.
DESIGN: PASS
```

**Scenario R-2: Three consecutive refresh failures — TTL not yet expired**

```
3 refresh errors over 60s. lastRefresh[X] updated from last SUCCESS (prior cycle).
If (now - lastRefresh[X]) < LOCK_TTL → warn but no invalidation yet.
If (now - lastRefresh[X]) >= LOCK_TTL → invalidated; kick.
DESIGN: PASS
```

**Scenario R-3: Refresh detects stolen session (token mismatch)**

```
Callback: current._session.token ≠ sessionTokens[X] → return nil.
Outer: result == nil → invalidated[X]=true; playerState="invalidated"; player kicked.
DESIGN: PASS
```

---

### Duplicate Save Scenarios

**Scenario D-1: Autosave + PlayerRemoving save (normal path)**

Both saves: state=="active"/"releasing"; token T_A captured; both UpdateAsync calls serialized by DataStore.
Both callbacks match T_A → both writes succeed (second is idempotent — same token, same data).
DESIGN: PASS

**Scenario D-2: Autosave after session invalidated**

```
Session loss detected; invalidated[X]=true; state="invalidated".
Autosave: savePlayer → state check: "invalidated" ≠ "active"/"releasing" → return false. PASS
```

---

### Shutdown Scenarios

**Scenario S-1: Normal shutdown (PlayerRemoving completes before BindToClose)**

```
PlayerRemoving: save + release → state "released"; loadedData[X]=nil.
BindToClose: savePlayer → state "released" → return false. releaseSession → state ≠ "active" → no-op.
DESIGN: PASS
```

**Scenario S-2: Rapid shutdown (BindToClose fires before PlayerRemoving completes)**

```
BindToClose: savePlayer(X) starts; token T_A captured; UpdateAsync yields.
PlayerRemoving: releaseSession → state "active"→"releasing"; sessionTokens[X]=nil; T_A captured.
BindToClose save callback: T_A matches DataStore → writes data. PASS
PlayerRemoving release callback: T_A matches → marks released=true. PASS
DESIGN: PASS
```

---

## Manual Test Plan (Pre-Implementation Checklist)

The following tests must be executed in Roblox Studio after implementation. None have been run against the current codebase.

| # | Test | Setup | Expected | Fail indicator |
|---|---|---|---|---|
| T-01 | New player load | Player with no prior data joins | DEFAULT_DATA returned; `_session` not in getData result | Error or nil from loadPlayer |
| T-02 | Returning player load | Player with saved data joins | Saved values loaded; new default fields added | Missing fields or wrong values |
| T-03 | DataStore unavailable on load | Disable Studio network | Player kicked; loadedData not populated | Player initialized with defaults |
| T-04 | Concurrent sessions (two Studio instances) | Two servers, same userId | Second server kicked on acquisition attempt | Both servers show player active |
| T-05 | TTL expiry allows rejoin | Kill first server without release; wait 60s | Second server acquires session normally | Second server kicked ("active on another server") |
| T-06 | Save preserves correct data | addCash(100); savePlayer; reload | Cash == 100 after reload | Cash == 0 or wrong value |
| T-07 | Save blocked after session loss | Simulate stolen session; trigger autosave | savePlayer returns false; player kicked | Save succeeds after session loss |
| T-08 | addCash blocked after session loss | Simulate stolen session; call addCash | addCash is a no-op; Cash unchanged | Cash increases after session loss |
| T-09 | spendCash blocked after session loss | Simulate stolen session; call spendCash | spendCash returns false | spendCash returns true |
| T-10 | Duplicate loadPlayer call | Call loadPlayer twice quickly (same player) | Second call returns nil with warning | Second call acquires session / overwrites first |
| T-11 | Release on PlayerRemoving | Player leaves normally | Session marked released=true in DataStore | Session not released (requires Studio DataStore viewer) |
| T-12 | Release idempotency | PlayerRemoving + BindToClose both fire | Exactly one release write; no duplicate token mismatch error | Error from second release or corrupted state |
| T-13 | BindToClose 25s deadline | 2+ players; slow DataStore | All saves attempted; server shuts down within 25s | Server hangs indefinitely |
| T-14 | Legacy data backward compat | Existing player record (no `_session` field) | Record loaded; all fields preserved; `_session` added | Data loss or load failure |
| T-15 | `_session` isolation | Inspect getData return value | No `_session` key in returned table | `_session` present in getData result |
| T-16 | Callback retry idempotency | Inject artificial Roblox retry (Studio debug) | Acquisition succeeds if token matches; aborts if token differs | Incorrect session state after retry |
| T-17 | Refresh detects stolen session | While player is active, manually write another token to DataStore | Player kicked on next refresh cycle | Player continues playing with stale session |
| T-18 | TTL-expired same-server session | Studio: same JobId; write old session with `since` > 60s ago | New load acquires session | Kicked as "active on another server" |

---

## Tests Added for Revision 5 (Architecture Issues D-10 through D-13)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Drain timeout: release NOT issued; session expires by TTL | D-10 — release after drain timeout | IW-2 |
| Save deadline exceeded: state→abandoned; inFlightSaves not cleared (drain path) | D-11 — cleanup race | IW-2 |
| Save deadline exceeded: state→abandoned; inFlightSaves deliberately cleared (save-stuck path) | D-11 | IW-3 |
| PlayerRemoving fires first; BindToClose observes shuttingDown | D-12 — single-owner disconnect | SO-1 |
| BindToClose fires first; PlayerRemoving observes shuttingDown | D-12 | SO-2 |
| Cooperative-scheduler guarantee prevents shuttingDown race | D-12 | SO-3 |
| Serialised saves — autosave drains before disconnect save; disconnect snapshot is freshest | D-12, overlapping saves | SO-4 |
| SR-1 updated: single save in flight; disconnect snapshot ≥ autosave snapshot | D-12 | SR-1 (Revision 5) |
| IW-1 corrected: late save preserves released=true; actual risk is stale snapshot | D-13 — IW-1 inaccuracy | IW-1 (corrected) |

## Tests Added for Revision 4 (Architecture Issues D-6 through D-9)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Save callback retried after loadedData cleared by releaseSession | D-6 — save snapshot | SS-1 |
| Two overlapping saves with different snapshots — ordering and staleness | D-6 | SS-2 |
| refreshSession — non-nil wrong-token result treated as ownership loss | D-8 — refresh verification | RV-1 |
| refreshSession — nil result treated as ownership loss | D-8 | RV-2 |
| releaseSession would have committed before in-flight save (Revision 3 defect) | D-9 — in-flight save wait | IW-1 |
| inFlightSaves deadline exceeded — degraded path | D-9 | IW-2 |
| Live same-server different-token blocked by TTL rule | D-7 — acquisition contradiction | DS-2 (revised) |
| Expired same-server session acquirable by TTL rule | D-7 | DS-3 (revised) |

## Tests Added for the Four Issues (Architecture Revision 3)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Callback retried after ownership change | Issue 1 — no closure mutation | CR-1 |
| Acquisition callback retried — idempotent | Issue 1 | CR-2 |
| Acquisition callback retried — another server intervened | Issue 1 | CR-3 |
| Duplicate same-server loadPlayer call | Issue 2 — same-server idempotency | DS-1 |
| Same-server different-token (live TTL) | Issue 2 | DS-2 |
| Same-server different-token (expired TTL) | Issue 2 | DS-3 |
| addCash blocked after refresh detects session loss | Issue 3 — mutation after ownership loss | ML-1 |
| addCash blocked after failed load | Issue 3 | ML-2 |
| getData allowed in "releasing" state | Issue 3 | ML-3 |
| In-flight save + concurrent release | Issue 4 — save/release coordination | SR-1 |
| New save attempt after sessionTokens cleared | Issue 4 | SR-2 |
| Duplicate releaseSession from PlayerRemoving + BindToClose | Issue 4 | SR-3 |
| Release UpdateAsync fails all retries — TTL safety net | Issue 4 | SR-4 |
| savePlayer called after "released" state | Issue 4 | SR-5 |
| T-10 (manual) | Issue 2 | DS-1 |
| T-16 (manual) | Issue 1 | CR-1, CR-2 |
| T-17 (manual) | Issue 3 | ML-1 |
| T-18 (manual) | Issue 2 | DS-3 |
