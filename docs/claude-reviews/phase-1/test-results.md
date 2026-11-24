# Phase 1 Test Results — Cash Empire Tycoon (Revision 12)

**Date:** 2026-11-25
**Commit under review:** b05aa20 (`feature/phase-1-data-foundation`)
**Review revision:** 12
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
| Duplicate disconnect ownership rejected | `shuttingDown[userId]` guard: first caller owns lifecycle; second (observing) caller performs two-phase wait: (1) until `shuttingDown` clears, (2) until `inFlightSaves == 0` — `disconnectCount` decremented only after both phases (R26) | Yes |
| BindToClose completes within 25 s deadline | Each player gets a concurrent `task.spawn(disconnectPlayer)`; observers use two-phase wait; counter reflects actual save completion; 25 s outer deadline provides exit if saves never complete (logs warning, allows shutdown) | Yes |
| Player can rejoin same server after disconnect | `playerState[userId]` is cleared to nil after all async ops complete; `loadPlayer` accepts nil state (R24); stale refresh from old session cannot invalidate new session (R23); stale autosave from old session cannot invalidate new session via §6.3 dual identity check (R28/R29/R30) | Yes |
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

**Scenario ML-3: `getData` called in state "disconnecting" (blocked)**

The "releasing" state was removed in Revision 5; the lifecycle transition is "active" → "disconnecting". `getData` accepts "active" only.

```
Setup:    PlayerRemoving fires; disconnectPlayer sets state→"disconnecting".
          Some code calls getData (e.g., a final balance check or income tick).
Step 1:   getData: playerState[X] == "disconnecting" ≠ "active" → return nil.
Step 2:   addCash/spendCash → getData returns nil → no-op / return false. PASS
Expected: getData is blocked during disconnect lifecycle. Game logic cannot mutate data
          while disconnectPlayer owns the lifecycle.
Note:     disconnectSave reads loadedData directly (via the snapshot parameter from
          disconnectPlayer), not through getData. This block does not affect the save path.
DESIGN: PASS
```

---

### Save Snapshot Correctness (NEW — Revision 4, D-6)

**Scenario SS-1: disconnectPlayer clears loadedData while autosave callback is mid-retry (drain-timeout path)**

```
Setup:    Server A: autosave (savePlayer) starts for Player X.
          token=T_A, snapshot=deepCopy(loadedData[X]) captured before UpdateAsync.
          loadedData[X] = {Cash:500}.
Step 1:   savePlayer UpdateAsync yields (callback in progress).
Step 2:   PlayerRemoving fires. disconnectPlayer(X): shuttingDown[X]=true; drain wait.
          Drain deadline exceeded (autosave stalled). state→"abandoned".
          Cleanup: loadedData[X]=nil (cleared by disconnectPlayer, not releaseSession).
Step 3:   Roblox retries autosave callback (ack lost on first attempt).
          Callback reads: snapshot (local variable, deepCopy) → {Cash:500} ✓
                          token (local variable) → T_A ✓
          Neither reads loadedData[X] (which is now nil).
Step 4:   current._session.token == T_A → callback writes {Cash:500, _session:{T_A}}.
Step 5:   result._session.token == T_A → save confirmed ✅
Expected: Correct data written even after disconnectPlayer cleared loadedData. DESIGN: PASS

Broken (Revision 3) behaviour at Step 3:
          Callback reads: loadedData[X] → nil → deepCopy(nil) → error or empty record ← WRONG
```

**Scenario SS-2: Autosave drains first; disconnect save takes fresher snapshot (current design)**

```
Current design (Revision 5+): saves are serialized by disconnectPlayer.

Setup:    Autosave (time T0) captures snapshot_T0 = {Cash:100}.
          addCash(50) runs: loadedData[X].Cash = 150.
          PlayerRemoving fires.
Step 1:   disconnectPlayer: drain wait; inFlightSaves[X]==1 → loops.
Step 2:   Autosave UpdateAsync completes; inFlightSaves[X]=0.
          DataStore: {Cash:100, _session:{T_A}}.
Step 3:   Drain passes. snapshot_T1=deepCopy(loadedData[X])={Cash:150}.
          disconnectSave(X, player, T_A, snapshot_T1); UpdateAsync.
Step 4:   disconnectSave callback: T_A matches → writes {Cash:150, _session:{T_A}}.
          inFlightSaves[X]=0; return true.
Step 5:   releaseSession → released=true.
Expected: Final DataStore = {Cash:150} (fresh snapshot). No two saves in-flight. DESIGN: PASS
```

Historical (Revision 4 — D-12 defect, fixed in Revision 5):

```
Both PlayerRemoving save and autosave in-flight simultaneously:
Step 1:   releaseSession waits for inFlightSaves[X] == 2 → loops.
Step 2:   DataStore serializes: PlayerRemoving save (snapshot_T1={Cash:150}) commits first.
Step 3:   Autosave (snapshot_T0={Cash:100}) commits last → overwrites disconnect save.
          Final DataStore: {Cash:100} ← DATA STALE (worst ordering).
Note:     This is Risk 6 in §15 of architecture.md. The current design eliminates
          this risk by draining autosaves before the disconnect save starts.
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
Step 2:   state→"abandoned"; loadedData[X]=nil; lastRefresh[X]=nil; shuttingDown[X]=nil.
          activeLocks[X]=nil (already cleared in step 2 of disconnectPlayer lifecycle).
          sessionTokens[X]=T_A preserved (D-20 fix; cleared by §6.3 Step 4 after autosave completes).
          inFlightSaves[X] NOT cleared (autosave owns its slot).
Step 3:   disconnectPlayer returns. No disconnect save. No release UpdateAsync.
Step 4:   Autosave eventually completes: inFlightSaves[X] decremented → 0.
          Callback: T_A matches DataStore → data written ✅
Step 5:   No refresh fires (activeLocks cleared at step 1). After LOCK_TTL seconds
          from last refresh, session expires. Another server acquires normally.
Expected: Session expires by TTL. Autosave snapshot preserved. No cleanup race. DESIGN: PASS
```

**Scenario IW-3: disconnectPlayer — disconnectSave all retries exhausted (TTL path)**

`disconnectSave` handles its own retries internally. When all retries are exhausted, it sets `inFlightSaves[userId] = 0` (always decremented), sets state to "disconnecting" (unchanged — disconnectPlayer checks return value and transitions to "abandoned"), and returns `false`. There is no external wait loop.

```
Setup:    Drain passes (inFlightSaves[X]=0). disconnectPlayer calls disconnectSave.
          disconnectSave: inFlightSaves[X]=1; UpdateAsync stalls. All SAVE_RETRIES fail.
Step 1:   disconnectSave: all attempts return !ok (DataStore error).
Step 2:   disconnectSave: inFlightSaves[X]=0 (unconditional decrement). return false.
Step 3:   disconnectPlayer: saveOk==false; playerState[X] not "abandoned" → set "abandoned".
          loadedData[X]=nil; inFlightSaves[X]=nil (already 0 — cleanup); shuttingDown[X]=nil.
          No release UpdateAsync.
Step 4:   Session expires by TTL (LOCK_TTL seconds from last _session.since write in DataStore,
          see §7.5 for in-flight refresh note).
Expected: inFlightSaves is 0 when disconnectPlayer cleans up (no nil-decrement risk).
          inFlightSaves cleared safely since disconnectSave already decremented to 0.
DESIGN: PASS
```

### Single-Owner Disconnect and Save Serialization (NEW — Revision 5, D-12)

**Scenario SO-1: PlayerRemoving fires first; BindToClose observes ownership (updated — Revision 9, D-19)**

```
Setup:    Server shutdown: PlayerRemoving fires for Player X.
Step 1:   PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle starts.
Step 2:   BindToClose fires. Iterates Players; Player X is in list.
          disconnectPlayer(X) → shuttingDown[X]==true → two-phase wait begins.
          Phase-1: while shuttingDown[X] do task.wait(0.05) end → loops (does NOT decrement disconnectCount).
Step 3:   PlayerRemoving lifecycle: drain→save→release→cleanup completes; shuttingDown[X]=nil.
Step 4:   BindToClose observer: Phase-1 exits. Phase-2: inFlightSaves[X]==nil → exits immediately.
          disconnectPlayer returns → disconnectCount -= 1 ✅ (after all operations complete).
Expected: Exactly one save, one release. No competing saves. DESIGN: PASS
```

**Scenario SO-2: BindToClose fires first; PlayerRemoving observes ownership (updated — Revision 9, D-19)**

```
Setup:    BindToClose fires before PlayerRemoving has called disconnectPlayer.
Step 1:   BindToClose: task.spawn → disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle.
Step 2:   PlayerRemoving fires.
          disconnectPlayer(X) → shuttingDown[X]==true → two-phase wait begins.
          Phase-1: loops on shuttingDown; Phase-2: loops on inFlightSaves.
Step 3:   BindToClose lifecycle: drain→save→release→cleanup completes; shuttingDown[X]=nil.
Step 4:   PlayerRemoving observer: both phases exit; disconnectPlayer returns. ✅
Expected: Exactly one save, one release. No competing saves. DESIGN: PASS
```

**Scenario SO-3: Cooperative-scheduler guarantee prevents shuttingDown race (updated — Revision 9, D-19)**

```
Setup:    Race: BindToClose task.spawn fires at the exact moment PlayerRemoving starts disconnectPlayer.
          Roblox cooperative scheduler: only one coroutine runs at a time between yields.
Step 1:   PlayerRemoving (runs first): disconnectPlayer(X) → sets shuttingDown[X]=true; yields at drain wait.
Step 2:   BindToClose spawn resumes: disconnectPlayer(X) → shuttingDown[X]==true → two-phase wait begins.
          (Cooperative scheduler means shuttingDown is set before any yield, so no actual race on the flag.)
Step 3:   PlayerRemoving lifecycle completes; BindToClose observer's two-phase wait exits. ✅
Expected: shuttingDown assignment is atomic at coroutine boundaries. No race. DESIGN: PASS
```

**Scenario SO-4: Serialised saves — autosave drains before disconnect save (Revision 5)**

```
Setup:    Autosave captures snapshot_T0={Cash:100}. addCash(50) runs: loadedData[X].Cash=150.
          Autosave UpdateAsync yields. PlayerRemoving fires.
Step 1:   disconnectPlayer(X): drain wait; inFlightSaves[X]==1 > 0 → loops.
Step 2:   Autosave UpdateAsync completes; inFlightSaves[X]=0.
          DataStore: {Cash:100, _session:{T_A}}.
Step 3:   Drain passes. disconnectPlayer takes snapshot_T1=deepCopy(loadedData[X])={Cash:150}.
Step 4:   disconnectSave(X, player, T_A, snapshot_T1); inFlightSaves[X]=1; UpdateAsync.
Step 5:   Disconnect save completes: result._session.token==T_A → ✅
          inFlightSaves[X]=0; return true. DataStore={Cash:150, _session:{T_A}}.
Step 6:   releaseSession → released=true. DataStore={Cash:150, _session:{T_A, released:true}} ✅
Expected: Final DataStore value is snapshot_T1={Cash:150}, the more recent snapshot.
          No two saves ever in-flight simultaneously. DESIGN: PASS

Contrast with Revision 4 (D-12):
Step 1:   PlayerRemoving savePlayer + BindToClose savePlayer both start; inFlightSaves[X]=2.
Step 3:   DataStore serializes: autosave (Cash:100) runs last → overwrites disconnect (Cash:150).
          Final DataStore: {Cash:100} ← DATA STALE (Revision 4 unfixed)
```

### Save/Release Concurrency (now handled by disconnectPlayer)

**Scenario SO-5: Autosave fires while in "disconnecting" state — rejected by savePlayer (NEW — Revision 6)**

```
Setup:    disconnectPlayer(X) has started; playerState[X]="disconnecting"; sessionTokens[X]=T_A (preserved — D-20 fix).
          A coroutine (autosave loop) calls savePlayer(X).
Step 1:   savePlayer: playerState[X] == "disconnecting" ≠ "active" → return false immediately.
          No DataStore call. No inFlightSaves increment. PASS
Step 2:   disconnectPlayer proceeds normally (drain already 0 or in progress; this call is a no-op).
Expected: Autosave in "disconnecting" state is a silent no-op. DESIGN: PASS
```

---

**Scenario IW-4: In-flight refresh at disconnect — TTL anchor analysis (NEW — Revision 6)**

```
Setup:    Server A: refreshSession task running (UpdateAsync in progress; token T_A captured).
          disconnectPlayer fires concurrently.
Step 1:   disconnectPlayer: activeLocks[X]=nil. (sessionTokens[X]=T_A preserved — D-20 fix.)
          Refresh loop will not start another refresh for X on next tick.
          But the currently-running refresh task continues with its captured token T_A.
Step 2:   In-flight refresh completes: current._session.token == T_A == captured token.
          Writes _session.since = T2 to DataStore.

Normal path:
Step 3:   disconnectPlayer: drain (inFlightSaves==0; refresh does not use inFlightSaves),
          snapshot taken, disconnectSave called.
Step 4:   disconnectSave commits: DataStore = {snapshot, _session:{T_A, since=T3}}.
          (Note: disconnect save writes new _session from current, updating since=T3.)
Step 5:   releaseSession → released=true in DataStore.
          In-flight refresh at T2 has no effect: released=true allows immediate acquisition.
DESIGN: PASS (normal path unaffected by in-flight refresh)

Abandoned path (if drain timeout):
Step 3:   disconnectPlayer: DRAIN_DEADLINE exceeded → state→"abandoned"; return.
Step 4:   DataStore has _session.since = T2 (from in-flight refresh at step 2).
          TTL countdown: another server can acquire at T2 + LOCK_TTL, NOT at T1 + LOCK_TTL.
          Worst case: T2 is LOCK_REFRESH (~20s) after T1 → another server waits up to
          LOCK_REFRESH + LOCK_TTL seconds from T1.
DESIGN: PASS with Risk 8 documented (TTL anchor is T2, not T1).
```

**Scenario IW-5: Refresh callback retry during disconnect — captured token prevents false ownership loss (NEW — Revision 7, D-15; updated — Revision 11)**

```
Setup:    Server A: refreshSession starts; local token = sessionTokens[X] = T_A captured.
          disconnectPlayer fires: activeLocks[X]=nil; state→"disconnecting".
          (sessionTokens[X]=T_A preserved — D-20 fix; not cleared in step 2.)
          Roblox retries refresh callback (network ack lost).
Step 1:   Refresh callback: current._session.token vs captured token T_A.
          captured T_A is a read-only local; it is unaffected by any change to sessionTokens[X].
          current._session.token == T_A → callback writes updated _session.since ✅
Step 2:   Refresh result handler: result._session.token == T_A → lastRefresh[X] updated.
          No ownership loss. No invalidation. No kick.
Step 3:   disconnectPlayer proceeds: drain (refresh does not use inFlightSaves).
          disconnectSave called; state still "disconnecting" ✅
Expected: Captured token prevents false ownership loss. disconnectSave unblocked. DESIGN: PASS

Broken (Revision 6) behaviour (historical):
          Revision 6: callback read live sessionTokens[X] instead of a captured local.
          disconnectPlayer (Revision 6) cleared sessionTokens[X]=nil in step 2.
          Callback: current._session.token ~= sessionTokens[X] (nil) → return nil.
          Result handler: result==nil → playerState[X]="invalidated".
          disconnectSave: playerState[X] ≠ "disconnecting" → return false. Final save skipped ← D-15
          Both root causes fixed: D-15 (captured token), D-20 (sessionTokens preserved).
```

**Scenario IW-6: Refresh completes while state is "disconnecting" — state guard prevents interference (NEW — Revision 7, D-15)**

```
Setup:    refreshSession is in-flight (UpdateAsync yielded). disconnectPlayer starts;
          state→"disconnecting". (sessionTokens[X]=T_A preserved — D-20 fix.)
          Refresh UpdateAsync eventually returns.
Case A:   result._session.token == T_A (refresh committed).
          Result handler: playerState[X] == "disconnecting" ≠ "active" → return false.
          No invalidation. No kick. ✅
Case B:   result._session.token ≠ T_A or result==nil (another server took over or nil).
          Result handler: playerState[X] == "disconnecting" ≠ "active" → return false.
          No invalidation overwrite. ✅ (disconnect lifecycle owns state)
Step next: disconnectSave proceeds; playerState[X] still "disconnecting" ✅
Expected: Refresh result cannot overwrite "disconnecting" state. disconnectSave unblocked. DESIGN: PASS
```

**Scenario IW-7: Refresh completes after releaseSession — state guard prevents interference (NEW — Revision 7, D-15)**

```
Setup:    refreshSession UpdateAsync is in-flight. disconnectPlayer completes:
          state→"released"; loadedData[X]=nil; sessionTokens[X]=nil.
          Delayed refresh result finally returns.
Step 1:   Refresh result handler: playerState[X] == "released" ≠ "active" → return false.
          No invalidation. No kick. ✅
Step 2:   If persistent-failure handler also fires (e.g., multiple errors after release):
          TTL check: playerState[X] ≠ "active" → return false. No kick. ✅
Expected: Post-release refresh completion is a silent no-op. DESIGN: PASS
```

### Rejoin Race Scenarios (NEW — Revision 8, D-16)

**Scenario RJ-1: Old T_A refresh completes with failure after T_B is active — dual check blocks invalidation**

```
Setup:    T_A disconnects; disconnectPlayer completes; playerState[X]=nil (cleanup).
          Player rejoins: loadPlayer → T_B active; playerState[X]="active"; sessionTokens[X]=T_B.
          Old T_A refreshSession UpdateAsync (captured T_A) finally returns nil.
Step 1:   §7.2 else branch: result==nil.
          First check: playerState[X]=="active" → passes.
          Second check: sessionTokens[X]==T_B ≠ T_A (captured) → FAILS → return false. ✅
Expected: T_B session unaffected. No invalidation. No kick. DESIGN: PASS

Broken (Revision 7) behaviour:
          Only first check ran: playerState=="active" → passed → playerState="invalidated"; T_B kicked ← D-16
```

**Scenario RJ-2: Old T_A refresh succeeds after T_B is active — identity check prevents lastRefresh update**

```
Setup:    T_A disconnects (DataStore still has T_A — T_B not yet written).
          Player rejoins: loadPlayer for T_B in progress (state="loading").
          T_A refresh UpdateAsync: current._session.token==T_A → callback matches → writes since=T2.
          result._session.token==T_A.
Step 1:   Success path dual check: playerState[X]=="loading" ≠ "active" → first check FAILS → return false. ✅
          lastRefresh[X] NOT updated.
Variant:  T_B fully active (state="active"; sessionTokens[X]=T_B) when T_A refresh returns.
          First check: playerState=="active" → passes.
          Second check: sessionTokens[X]==T_B ≠ T_A → FAILS → return false. ✅
          lastRefresh[X] NOT updated to stale T_A's time.
Expected: Stale successful refresh silently ignored; T_B's lastRefresh unaffected. DESIGN: PASS
```

**Scenario RJ-3: Persistent refresh failure from T_A after T_B is active — dual check prevents kick**

```
Setup:    T_A disconnects; T_B active (state="active"; sessionTokens[X]=T_B).
          T_A refresh has been failing; now os.time()-lastRefresh[X] > LOCK_TTL (§7.3 TTL path).
Step 1:   §7.3: first check: playerState[X]=="active" → passes.
          Second check: sessionTokens[X]==T_B ≠ T_A (captured by T_A refresh) → FAILS → return false. ✅
Expected: T_A's expired lock does not invalidate or kick T_B session. DESIGN: PASS
```

**Scenario BC-1: BindToClose with PlayerRemoving owning lifecycle; normal completion — two-phase wait (Revision 9)**

See Timeline C for detailed step-by-step. Summary:

```
PlayerRemoving owns lifecycle (drain+save+release).
BindToClose observer: Phase-1 wait on shuttingDown; Phase-2 wait on inFlightSaves.
Normal path: Phase-2 immediate (inFlightSaves nil after step-7 cleanup).
Observer returns → disconnectCount -= 1 ✅ (after all operations complete).
DESIGN: PASS
```

**Scenario BC-2: PlayerRemoving owns; drain times out; autosave in flight; BindToClose must not report false completion (NEW — Revision 9, D-17)**

See Timeline G for detailed step-by-step. Summary:

```
PlayerRemoving: drain timeout → shuttingDown[X]=nil; inFlightSaves[X]=1 still.
BindToClose observer: Phase-1 exits (shuttingDown nil). Phase-2: inFlightSaves=1 → loops.
disconnectCount NOT decremented until autosave completes (inFlightSaves→0). ✅

Broken (Revision 8): Phase-1 only → observer returned immediately after Phase-1 →
disconnectCount -= 1 while autosave still in flight ← D-17
DESIGN: PASS (Revision 9)
```

**Scenario BC-3: BindToClose owns; drain times out; PlayerRemoving observes; same two-phase wait (NEW — Revision 9, D-17)**

See Timeline H for detailed step-by-step. Summary:

```
BindToClose: drain timeout → shuttingDown[X]=nil; inFlightSaves[X]=1 still.
PlayerRemoving observer: same two-phase wait; Phase-2 loops until autosave completes. ✅
DESIGN: PASS
```

**Scenario BC-4: Autosave completes after drain timeout; playerState cleared; same-server rejoin enabled (NEW — Revision 9, D-17)**

See Timeline I for detailed step-by-step. Summary:

```
Drain timeout: playerState[X]="abandoned"; inFlightSaves[X]=1; shuttingDown[X]=nil.
Autosave eventually commits: inFlightSaves[X]→0; §6.3 clears playerState[X]=nil.
Player rejoins: loadPlayer → playerState[X]==nil → allowed; new session T_B starts. ✅
DESIGN: PASS
```

**Scenario BC-5: BindToClose 25-second deadline reached with saves still outstanding (NEW — Revision 9, D-17)**

See Timeline J for detailed step-by-step. Summary:

```
Two players; both stalled autosaves in drain-timeout path.
BindToClose observers in Phase-2 wait; autosaves never complete within 25s.
Outer loop: os.clock()-deadline >= 25s → exits. disconnectCount=2 > 0.
warn("[DataManager] BindToClose: 25s deadline reached with 2 player(s) with
      outstanding saves or disconnect in progress.")
BindToClose returns. Stalled saves abandoned when server shuts down.
Data loss documented as degraded-path outcome.
DESIGN: PASS (degraded path with correct logging)
```

**Scenario DT-1: T_A autosave succeeds after drain timeout; old session cleaned up; T_B rejoin succeeds (NEW — Revision 10, D-20)**

See Timeline I (updated) for detailed step-by-step. Summary:

```
Drain timeout: playerState[X]="abandoned"; inFlightSaves[X]=1; sessionTokens[X]=T_A (preserved).
Autosave completes; callback: current._session.token==T_A → data written.
§6.3 Step 1: inFlightSaves→0. Step 2: sessionTokens==T_A==capturedToken → passes.
Step 3: confirmedSessionLoss=false → skip. Step 4: abandoned AND counter==0
→ sessionTokens=nil; playerState=nil. ✅ T_B rejoin: loadPlayer → playerState==nil → allowed. ✅
DESIGN: PASS
```

**Scenario DT-2: T_A autosave detects token mismatch after drain timeout; T_B not invalidated or kicked (NEW — Revision 10, D-20)**

See Timeline K for detailed step-by-step. Summary:

```
Drain timeout: playerState[X]="abandoned"; sessionTokens[X]=T_A.
Autosave confirms session loss (DataStore has another token).
§6.3 Step 1: inFlightSaves→0. Step 2: sessionTokens==T_A==capturedToken → passes.
Step 3: confirmedSessionLoss=true; playerState=="abandoned" (NOT "active")
→ warn log; skip invalidation; skip kick. Step 4: abandoned AND counter==0
→ sessionTokens=nil; playerState=nil. ✅

Broken (Revision 9): confirmedSessionLoss fired → playerState="invalidated" →
drain-timeout cleanup skipped → playerState stayed "invalidated" forever → rejoin blocked. ← D-20
DESIGN: PASS (Revision 10)
```

**Scenario DT-3: T_A autosave exhausts DataStore retries after drain timeout; T_B not affected (NEW — Revision 10, D-20)**

```
Drain timeout: playerState[X]="abandoned"; inFlightSaves[X]=1; sessionTokens[X]=T_A.
Autosave: all SAVE_RETRIES fail (DataStore errors only). saveSucceeded=false; confirmedSessionLoss=false.
§6.3 Step 1: inFlightSaves→0. Step 2: sessionTokens==T_A → passes.
Step 3: confirmedSessionLoss=false → skip. Step 4: abandoned AND counter==0
→ sessionTokens=nil; playerState=nil. warn "all retries exhausted". ✅
T_B rejoin proceeds; session expires by TTL.
DESIGN: PASS
```

**Scenario DT-4: T_A completion races with T_B load; T_B cannot start until T_A safely relinquishes state (NEW — Revision 10, D-20; expanded — D-20 deep review)**

```
Structural proof (both paths):

Normal path:
  §10.1 drain waits until inFlightSaves[X]=0 — all T_A autosaves complete before proceeding.
  disconnectSave runs: inFlightSaves[X]=1→0 on completion (synchronous).
  Step 7 cleanup: playerState[X]=nil (enables T_B load); inFlightSaves[X]=nil.
  By the time playerState=nil, every T_A save has completed and decremented.
  T_B starts with inFlightSaves=nil. No T_A save is ever "very late" after a normal release.

Drain-timeout path:
  §5.1: loadPlayer rejects if playerState[X] ~= nil.
  playerState[X]="abandoned" (non-nil) until §6.3 Step 4 clears it.
  §6.3 Step 4 fires only when inFlightSaves[X]==0 — AFTER Step 1 decremented the last counter slot.
  Step 4 sets playerState[X]=nil in the same call that decremented the last counter.
  T_B can only load AFTER that final save completed and decremented.
  No other T_A save is in flight (Step 4 requires counter==0 to fire).

Invariant: "T_B never starts while T_A's inFlightSaves slot is live."
In both paths this is structurally guaranteed — not merely prevented, but impossible.

Safety implication: If this invariant were violated (scheduler anomaly, future code change),
T_A's Step 1 decrement would reduce T_B's counter, potentially allowing Phase-2 to exit
before T_B's save completes. Step 2 identity check blocks further T_A state modifications,
but cannot undo the decrement. The structural guarantee must hold.

DESIGN: PASS (structural impossibility proven for both normal and drain-timeout paths)
```

**Scenario DT-5: Stale T_A save completion after T_B is fully active; Step-2 identity check blocks T_A (NEW — Revision 10, D-20)**

See Timeline L for detailed step-by-step. Summary:

```
T_B active: playerState[X]="active"; sessionTokens[X]=T_B.
T_A's very-late save fires (structural impossibility per DT-4 — documented as defence-in-depth only).
§6.3 Step 1: inFlightSaves[X] decremented.
§6.3 Step 2: sessionTokens[X]==T_B ≠ capturedToken(T_A) → stale completion → return false. ✅
T_B state untouched; no invalidation, no kick.
DESIGN: PASS (defence-in-depth; §5.1+two-phase-wait prevent this in practice)
```

**Scenario DT-6: §6.3 Step 4 → Phase-2 signal chain; BindToClose observer exits after save completes (REVISED — D-20 deep review, M-3)**

```
Preconditions:
  T_A autosave in flight: inFlightSaves[X]=1; playerState[X]="abandoned"; sessionTokens[X]=T_A.
  disconnectPlayer owner has exited (shuttingDown[X]=nil).
  BindToClose observer in Phase-2: while (inFlightSaves[X] or 0) > 0 do task.wait(0.05) end.

Signal chain when T_A autosave completes:
  §6.3 Step 1: inFlightSaves[X] = math.max(0, 1 - 1) = 0.
  §6.3 Step 2: sessionTokens[X]==T_A==capturedToken → identity check passes.
  §6.3 Step 3: confirmedSessionLoss=false → skip.
  §6.3 Step 4: playerState[X]=="abandoned" AND inFlightSaves[X]==0
               → sessionTokens[X]=nil; inFlightSaves[X]=nil; playerState[X]=nil.

Phase-2 observer next iteration:
  (inFlightSaves[X] or 0) = (nil or 0) = 0 → 0 > 0 is false → Phase-2 loop exits.
  disconnectPlayer observer returns → disconnectCount -= 1 ✅

Ordering guarantee:
  §6.3 Step 4 fires before Phase-2 exits. Rejoin eligibility (playerState=nil) and
  BindToClose count decrement are both correct.

DESIGN: PASS (concrete signal chain: §6.3 Step 1 → Step 4 → Phase-2 exit → counter decrement)
```

**Scenario DT-7: §6.3 Step 4 counter guard — only last save triggers cleanup (NEW — D-20 deep review)**

```
Precondition (theoretical — single autosave loop serialises saves, but validates protocol):
  Two saves in flight: inFlightSaves[X]=2; playerState[X]="abandoned"; sessionTokens[X]=T_A.
  Both saves captured capturedToken=T_A.

Save #1 completes first:
  Step 1: inFlightSaves[X] = 2 - 1 = 1.
  Step 2: sessionTokens[X]==T_A → passes.
  Step 3: confirmedSessionLoss=false → skip.
  Step 4: inFlightSaves[X]==1 ≠ 0 → condition false → Step 4 NOT triggered.
  Step 5: returns saveSucceeded. playerState unchanged ("abandoned").

Save #2 completes last:
  Step 1: inFlightSaves[X] = 1 - 1 = 0.
  Step 2: sessionTokens[X]==T_A → passes.
  Step 3: skip.
  Step 4: inFlightSaves[X]==0 AND playerState=="abandoned"
          → sessionTokens[X]=nil; inFlightSaves[X]=nil; playerState[X]=nil. ✅

Result: Cleanup fires exactly once; only after all saves complete. No premature state clearing.
Note:   The current design has at most one autosave in flight per player (autosave loop is
        sequential; disconnectSave runs after drain). This test validates the protocol's
        correctness under multiple concurrent saves for future multi-call scenarios.
DESIGN: PASS (protocol handles N in-flight saves; only the last triggers drain-timeout cleanup)
```

**Scenario DT-8: §6.3 Step 4 idempotency — second execution blocked by Step 2 (NEW — D-20 deep review)**

```
Setup: Two save coroutines both in drain-timeout path; playerState[X]="abandoned"; inFlightSaves[X]=2.

Coroutine A fires first:
  Step 1: inFlightSaves[X] = 2 - 1 = 1.
  Step 4: inFlightSaves==1 ≠ 0 → not triggered. Returns.

Coroutine B fires second (last save):
  Step 1: inFlightSaves[X] = 1 - 1 = 0.
  Step 2: sessionTokens[X]==T_A → passes.
  Step 4: abandoned AND counter==0 → sessionTokens[X]=nil; inFlightSaves[X]=nil; playerState[X]=nil.

Hypothetical third execution (e.g., stale callback, scheduler anomaly) after Step 4 cleared state:
  Step 2: sessionTokens[X]==nil ≠ capturedToken(T_A) → stale → return false immediately.
  Step 4 not reached; state unchanged (already nil or T_B's).

Result: Step 4 is idempotent — a second execution is blocked by Step 2 before it can clear T_B's state.
DESIGN: PASS (Step 2 identity check protects Step 4 idempotency)
```

**Scenario DT-9: Risk 8 — in-flight refresh extends TTL after disconnect; local state unaffected (NEW — D-20 deep review, L-1)**

```
Preconditions:
  T_A active; refresh task starts: local capturedToken=T_A; UpdateAsync yields inside callback.
  disconnectPlayer fires: activeLocks[X]=nil; drain timeout; playerState[X]="abandoned".
  sessionTokens[X]=T_A preserved (D-20 fix).

Refresh callback completes while UpdateAsync is still in flight:
  callback: current._session.token==T_A==capturedToken → match.
  callback writes: newRecord._session.since = os.time() → DataStore updated. ← Risk 8

§7.2 result handler fires:
  First check: playerState[X]=="abandoned" ≠ "active" → return false. ✅
  Local state: playerState, lastRefresh, invalidated — all untouched. ✅

DataStore state:
  _session.since = now (time of refresh write, NOT time of disconnect start).
  TTL countdown: another server must wait LOCK_TTL (60s) from this refresh write.
  Worst case: refresh completed immediately after disconnect → up to ~20s extra TTL delay.

D-20 interaction: D-20 preserves sessionTokens in memory but does not change the refresh
  callback's captured token or its DataStore write behaviour. Risk 8 is unaffected by D-20.

Result: Local state correctly protected. DataStore TTL extended (accepted risk — see §15 Risk 8).
DESIGN: PASS (local state) / ACCEPTED RISK (DataStore TTL delay, unmitigated by D-20)
```

---

**Scenario SR-1: Autosave in-flight when PlayerRemoving fires (updated for Revision 6)**

```
Setup:    Autosave in flight (inFlightSaves[X]=1; snapshot_T0 captured). PlayerRemoving fires.
Step 1:   disconnectPlayer(X): shuttingDown[X]=true; activeLocks[X]=nil; drain wait.
          (sessionTokens[X] NOT cleared in step 2 — D-20 fix.)
Step 2:   Autosave completes; inFlightSaves[X]=0 → drain passes.
Step 3:   snapshot_T1=deepCopy(loadedData[X]) taken (most recent data after drain).
          disconnectSave(X, player, T_A, snapshot_T1); inFlightSaves[X]=1; UpdateAsync.
Step 4:   Disconnect save completes: result._session.token==T_A → ✅; inFlightSaves[X]=0; return true.
Step 5:   releaseSession → released=true ✅.
Expected: One save at a time. Final state = snapshot_T1 ≥ snapshot_T0. DESIGN: PASS
```

**Scenario SR-2: Autosave attempt while in "disconnecting" state**

```
Setup:    disconnectPlayer in progress; state[X]="disconnecting"; sessionTokens[X]=T_A (preserved — D-20 fix).
          An autosave coroutine calls savePlayer(X).
Step 1:   savePlayer: playerState[X] == "disconnecting" ≠ "active" → return false immediately. PASS
          (token capture not reached; state check is sufficient.)
Expected: Autosave rejected before any DataStore call. DESIGN: PASS
Note:     The state guard alone blocks savePlayer in "disconnecting" state. sessionTokens preservation
          (D-20 fix) is not needed to block autosaves; it serves the §6.3 Step 2 identity check
          in the drain-timeout path.
```

**Scenario SR-3: Both PlayerRemoving and BindToClose call disconnectPlayer**

```
Setup:    Server shutdown: PlayerRemoving and BindToClose both fire for Player X.
Step 1:   Thread A (PlayerRemoving): disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle.
Step 2:   Thread B (BindToClose): disconnectPlayer(X) → shuttingDown[X]==true → two-phase wait begins.
          Phase-1: loops on shuttingDown. Phase-2: loops on inFlightSaves.
Step 3:   Thread A lifecycle: drain→disconnectSave→releaseSession→cleanup → shuttingDown[X]=nil.
Step 4:   Thread B observer: both phases exit → disconnectPlayer returns → disconnectCount -= 1 ✅
Expected: Exactly one save, one release. No competing saves or releases. DESIGN: PASS
Note:     See SO-1/SO-2/BC-1 for detailed timelines. "return immediately" (Revision 8) replaced by
          two-phase wait (Revision 9, D-17/D-19).
```

**Scenario SR-4: Release UpdateAsync fails all retries**

```
Setup:    PlayerRemoving fires; disconnectSave succeeds; releaseSession starts;
          all 3 release UpdateAsync attempts fail (DataStore errors only).
Step 1:   released = false after loop.
Step 2:   warn("Release failed for userId=X. Lock will expire after ~60s.").
Step 3:   playerState[X] = "abandoned" (all retries exhausted → TTL path).
Step 4:   activeLocks[X] was cleared by disconnectPlayer — refresh loop no longer refreshes X.
Step 5:   DataStore: X's session TTL counts down from last successful _session.since write.
Step 6:   After LOCK_TTL=60s from that write, session expires → available for acquisition on rejoin.
Expected: Session expires via TTL. No permanent lock. DESIGN: PASS (with up to 60s delay before rejoin)
```

**Scenario SR-5: `savePlayer` called after state is "released"**

```
Setup:    PlayerRemoving has completed; state = "released"; loadedData[X] = nil.
          BindToClose fires and tries savePlayer(X).
Step 1:   savePlayer: playerState[X] == "released" → not "active" → return false. PASS
Expected: No DataStore call. DESIGN: PASS
```

---

### Concurrency Scenarios (from previous revision, updated)

**Scenario C-1: Normal acquire → save → release**

```
Expected: acquisition confirmed by token match; autosave confirmed by token match;
          disconnectPlayer: drain→disconnectSave→releaseSession → released=true.
State transitions: nil→loading→active→disconnecting→released. DESIGN: PASS
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
Case 2: Server B acquires first (T_B in DataStore). Server A refresh callback: captured T_A ≠ T_B → nil.
        Server A: state=="active" → invalidated[X]=true → Server A kicks its player.
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
Callback: captured token T_A; current._session.token == T_B ≠ T_A → return nil.
Outer: result == nil; playerState[X]=="active" → state guard passes →
       invalidated[X]=true; playerState="invalidated"; player kicked.
DESIGN: PASS
```

---

### Duplicate Save Scenarios

**Scenario D-1: Autosave then PlayerRemoving (serialized by disconnectPlayer)**

```
Autosave runs while state=="active"; token T_A captured; UpdateAsync completes.
PlayerRemoving fires: disconnectPlayer starts; state→"disconnecting".
drain wait: inFlightSaves[X]==0 (autosave already done) → pass immediately.
snapshot taken; disconnectSave called with T_A.
One save at a time — no two saves in-flight simultaneously. DESIGN: PASS
```
Note: The old model (two saves both in-flight, serialized by DataStore) was fixed in Revision 5
(D-12). The current design serializes saves: autosave first, disconnect save only after drain.

**Scenario D-2: Autosave after session invalidated**

```
Session loss detected; invalidated[X]=true; state="invalidated".
Autosave: savePlayer → state check: "invalidated" ≠ "active" → return false. PASS
```

---

### Shutdown Scenarios

**Scenario S-1: Normal shutdown (PlayerRemoving completes before BindToClose)**

```
PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; drain→disconnectSave→releaseSession.
               state→"released"; loadedData[X]=nil; shuttingDown[X]=nil.
BindToClose: disconnectPlayer(X) → shuttingDown[X]==true → two-phase wait; both phases exit
             immediately (normal path). disconnectCount -= 1 ✅ (after all operations confirmed done).
DESIGN: PASS

Historical (pre-Revision 5): PlayerRemoving called savePlayer+releaseSession directly;
BindToClose called savePlayer independently. Replaced by disconnectPlayer in Revision 5.
```

**Scenario S-2: Rapid shutdown (BindToClose fires before PlayerRemoving completes)**

```
Both fire: disconnectPlayer with shuttingDown guard ensures single-owner lifecycle.
See SO-1 (PlayerRemoving first) and SO-2 (BindToClose first) for the two orderings.
The old model (BindToClose calls savePlayer, PlayerRemoving calls releaseSession independently)
is replaced by disconnectPlayer in Revision 5. No competing saves or releases are possible.
DESIGN: PASS (via disconnectPlayer)
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

## Tests Added for Revision 10 (Architecture Issue D-20)

| Test | Issue covered | Scenario reference |
|---|---|---|
| T_A autosave succeeds after drain timeout; session cleaned up; T_B rejoin succeeds | D-20 — §6.3 Step 4 drain-timeout cleanup | DT-1 (new), Timeline I (updated) |
| T_A autosave confirms session loss (token mismatch) after drain timeout; no invalidation; no kick; rejoin enabled | D-20 — §6.3 Step 3 state-conditional; Step 4 cleanup | DT-2 (new), Timeline K |
| T_A autosave exhausts retries after drain timeout; confirmedSessionLoss=false; cleanup clears state | D-20 | DT-3 (new) |
| §5.1 ordering invariant proves T_B cannot start while T_A's inFlightSaves slot is live | D-20 — counter ownership proof | DT-4 (new) |
| Stale T_A save completion after T_B active; Step-2 identity check blocks T_A (defence-in-depth) | D-20 — §6.3 Step 2 dual identity check | DT-5 (new), Timeline L |
| BindToClose §6.3 Step 4 → Phase-2 signal chain; concrete step-by-step (revised from references-only) | D-20 deep review (M-3) | DT-6 (revised) |
| §6.3 Step 4 counter guard — only last save triggers cleanup; Step 4 not triggered prematurely | D-20 deep review | DT-7 (new) |
| §6.3 Step 4 idempotency — second execution blocked by Step 2 identity check | D-20 deep review | DT-8 (new) |
| Risk 8 concrete scenario — in-flight refresh extends TTL; local state protected; D-20 no-interaction confirmed | D-20 deep review (L-1) | DT-9 (new) |
| DT-4 expanded with both-path structural impossibility proof | D-20 deep review (M-1) | DT-4 (expanded) |
| Timeline L note corrected to state structural impossibility | D-20 deep review (M-1) | Timeline L (updated) |
| §6.3 Step 4 adds inFlightSaves[userId]=nil for consistency with step-7 cleanup | D-20 deep review (M-2) | §6.3 Step 4 (updated) |
| SR-1 updated: sessionTokens NOT cleared in disconnectPlayer step 2 (D-20 fix) | D-20 | SR-1 (updated) |
| All timelines (A/B/C/D/E/F/G/H/I) updated: sessionTokens cleared in step 7 / §6.3, not step 2 | D-20 | Timelines A–L (updated) |

## Tests Added for Revision 9 (Architecture Issues D-17, D-18, D-19)

| Test | Issue covered | Scenario reference |
|---|---|---|
| PlayerRemoving owns; BindToClose observes; two-phase wait; normal completion | D-19 — SO-1 "return immediately" corrected | BC-1, SO-1 (updated) |
| PlayerRemoving owns; drain times out; autosave in flight; BindToClose Phase-2 blocks until save completes | D-17 — premature disconnectCount decrement in drain-timeout path | BC-2 (new), Timeline G |
| BindToClose owns; drain times out; PlayerRemoving observes; same two-phase wait | D-17 | BC-3 (new), Timeline H |
| Autosave completes after drain timeout; §6.3 clears playerState=nil; same-server rejoin enabled | D-17 | BC-4 (new), Timeline I |
| BindToClose 25s deadline reached with saves outstanding; warn logged; degraded-path documented | D-17 | BC-5 (new), Timeline J |
| Old refresh completes after T_B active; dual identity check blocks T_B state modification | D-18 — refresh task exempted from drain (dual check safety) | RJ-1/RJ-2/RJ-3 (preserved from R8) |
| Explicit categorization: saves tracked (must drain); refresh tasks not tracked (safe to outlive) | D-18 | §10.1 D-18 async operations table |
| SO-1/SO-2/SO-3/SR-3/S-1 updated: "return immediately" → two-phase wait | D-19 — contradictory shutdown documentation | SO-1, SO-2, SO-3, SR-3, S-1 (updated) |

## Tests Added for Revision 8 (Architecture Issues D-16)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Old T_A refresh failure after T_B active — dual check blocks invalidation/kick | D-16 — stale refresh invalidates new session | RJ-1 |
| Old T_A refresh success after T_B active — identity check blocks lastRefresh update | D-16 | RJ-2 |
| Persistent T_A refresh failure after T_B active — dual TTL-expiry check blocks kick | D-16 | RJ-3 |
| BindToClose observe-and-wait: second disconnectPlayer caller waits for owner before returning | D-16 — premature disconnectCount decrement | BC-1 |
| Timeline C/D updated: observing caller waits on shuttingDown before returning | D-16 | Timeline C, D (updated) |
| Rejoin acceptance criterion added: playerState cleared to nil enables same-server rejoin | D-16 — cleanup contradiction | Acceptance criteria (updated) |

## Tests Added for Revision 7 (Architecture Issue D-15)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Refresh callback retry after sessionTokens cleared — captured token prevents false ownership loss | D-15 — live sessionTokens read in callback | IW-5 |
| Refresh completion during "disconnecting" state — state guard prevents invalidation | D-15 — invalidated overwrites disconnect state | IW-6 |
| Refresh completion after releaseSession (state "released") — state guard no-op | D-15 | IW-7 |
| R-3 updated: callback uses captured T_A, not live sessionTokens | D-15 | R-3 (updated) |
| SS-1 updated: loadedData cleared by disconnectPlayer, not releaseSession | D-15 / correctness | SS-1 (updated) |
| SS-2 updated: current serialized design replaces Revision 4 dual-save | D-15 / D-12 historical | SS-2 (updated) |
| S-1 updated: disconnectPlayer replaces direct savePlayer+releaseSession | D-15 / Revision 5 | S-1 (updated) |
| D-1 updated: single serialized save path, no dual-save model | D-15 / D-12 historical | D-1 (updated) |

## Tests Added for Revision 6 (Architecture Issues D-14, Risk 8)

| Test | Issue covered | Scenario reference |
|---|---|---|
| Autosave rejected in "disconnecting" state by savePlayer state guard | D-14 — savePlayer rejects disconnect save | SO-5 |
| disconnectSave called with explicit token+snapshot after drain | D-14 | SO-4 (updated), SR-1 (updated) |
| In-flight refresh can extend TTL anchor in abandoned path | Risk 8 — in-flight refresh TTL extension | IW-4 |
| getData blocked in "disconnecting" state (not "releasing") | D-14 / "releasing" state removed | ML-3 (updated) |
| SR-4: release failure transitions to "abandoned" (not "released") | D-14 / state machine consistency | SR-4 (updated) |
| IW-3 (save failure): disconnectSave decrements inFlightSaves before returning | D-14 / no nil-decrement risk | IW-3 (updated) |

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
| Save callback retried after loadedData cleared by disconnectPlayer (drain-timeout path) | D-6 — save snapshot | SS-1 (updated) |
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
| getData blocked in "disconnecting" state (historical: "releasing" state; renamed in Revision 5) | Issue 3 | ML-3 (updated) |
| In-flight save + concurrent release | Issue 4 — save/release coordination | SR-1 |
| New save attempt after sessionTokens cleared | Issue 4 | SR-2 |
| Duplicate releaseSession from PlayerRemoving + BindToClose | Issue 4 | SR-3 |
| Release UpdateAsync fails all retries — TTL safety net | Issue 4 | SR-4 |
| savePlayer called after "released" state | Issue 4 | SR-5 |
| T-10 (manual) | Issue 2 | DS-1 |
| T-16 (manual) | Issue 1 | CR-1, CR-2 |
| T-17 (manual) | Issue 3 | ML-1 |
| T-18 (manual) | Issue 2 | DS-3 |
