# Phase 1 Implementation Report — Cash Empire Tycoon (Revision 9)

**Date:** 2026-11-24
**Branch:** `feature/phase-1-data-foundation` (commit b05aa20)
**Review branch:** `claude-review/phase-1`
**Status:** Revision 9 — pending approval before implementation

---

## Deliverable Status

| Deliverable | Status | Notes |
|---|---|---|
| Session locking prevents concurrent writes | Partial | Single-key design specified; not yet implemented |
| Three-case load distinction | Implemented (b05aa20) | New / existing / failed correctly distinguished |
| `UpdateAsync` for all writes | Partial | Implemented in b05aa20 but save callback does not verify token |
| Retry with backoff | Implemented (b05aa20) | In savePlayer; LOAD_RETRIES not yet present |
| `loadFailed` guard on saves and reads | Partial | `loadFailed` blocks saves; does not block `getData`/`addCash`/`spendCash` |
| Safe shutdown (`BindToClose`) | Implemented (b05aa20) | 25 s deadline, parallel saves |
| `MapReady` signal | Implemented (b05aa20) | MapBuilder writes BoolValue; TycoonManager waits on it |

---

## Defects Found in b05aa20

### D-1: Two-DataStore architecture (CRITICAL)

**File:** `PlayerDataManager.lua`

`TycoonSessionLocks_v1` and `TycoonPlayerData_v1` are separate DataStore keys. There is no cross-key atomic operation in Roblox DataStores. `savePlayer` cannot verify that the server still holds the lock at the time the data is written — the lock may have expired or been claimed by another server between the lock check and the data write.

**Fix:** Embed `_session` metadata inside `TycoonPlayerData_v1`. Remove `TycoonSessionLocks_v1` entirely. All lock logic (acquire, verify, refresh, release) becomes a single `UpdateAsync` on the player's one key. See architecture §1.

---

### D-2: Unconditional save write (CRITICAL)

**File:** `PlayerDataManager.lua`, `savePlayer`

```lua
PlayerStore:UpdateAsync(userId, function(_current)
    return data   -- ignores current; writes unconditionally
end)
```

The callback ignores `_current` entirely. It writes `data` regardless of whether this server still holds the session. A server that lost its session will silently overwrite another server's data.

**Fix:** Save callback must verify `current._session.token == token` (the token captured before entering UpdateAsync). If the token does not match, return nil — no write. See architecture §6.2.

---

### D-3: Closure mutation in UpdateAsync callback (CRITICAL)

**File:** `PlayerDataManager.lua`, `acquireLock`

```lua
local acquired = false
LockStore:UpdateAsync(userId, function(current)
    ...
    acquired = true   -- set inside callback
    return { ... }
end)
return acquired
```

Roblox may invoke the UpdateAsync callback multiple times on retry. If call 1 sets `acquired = true` then call 2 returns nil (session taken by another server), the outer function still sees `acquired == true` and reports success. The session may not have been acquired.

**Fix:** Never set correctness-critical variables inside the UpdateAsync callback. Verify acquisition only from the return value: `ok == true AND result ~= nil AND result._session.token == token`. See architecture §5.4.

---

### D-4: `loadFailed` does not block `getData` (HIGH)

**File:** `PlayerDataManager.lua`, `getData`

```lua
function PlayerDataManager.getData(player)
    return loadedData[tostring(player.UserId)]  -- no loadFailed check
end
```

`loadFailed[userId]` blocks `savePlayer` but `getData` returns `loadedData[userId]` unconditionally. After a mid-game session loss, `addCash` and `spendCash` both call `getData` and can still modify the in-memory profile. Those mutations will be lost (the save is blocked) but the player sees incorrect currency balances and can spend currency they no longer have permission to spend.

**Fix:** Introduce `invalidated[userId]` (replacing `loadFailed`) that covers both initial load failure and mid-game session loss. `getData` checks `invalidated[userId]` before returning data. See architecture §9.

---

### D-5: Stolen session not detected on refresh (HIGH)

**File:** `PlayerDataManager.lua`, refresh logic

The refresh function calls `UpdateAsync` to extend the lock TTL but does not verify the token in the returned record. If another server has acquired the session (overwriting the token), the refresh will silently succeed (writing our job ID back over their session) or silently fail — but the outer code takes no action either way. No invalidation, no kick.

**Fix:** Refresh callback verifies `current._session.token == sessionTokens[userId]`. If the token does not match, return nil and treat as confirmed session loss. See architecture §7.2.

---

## Architectural Issue: No Per-Player Lifecycle State (HIGH)

There is no formal state machine governing player data lifecycle. This creates several gaps:

- Two concurrent `loadPlayer` calls for the same player (e.g., rapid rejoin) can race, with the second potentially overwriting the first's session.
- After `releaseSession` clears `sessionTokens[userId]`, a concurrent in-flight save that already captured the token still holds a reference to it. Without a state guard, `releaseSession` can be called twice by both `PlayerRemoving` and `BindToClose`, writing two release records.
- No mechanism prevents `savePlayer` from starting after the session has been released.

**Fix:** Introduce `playerState[userId]` state machine with states: `nil/"loading"/"active"/"releasing"/"released"/"failed"/"invalidated"`. All operations check state before proceeding. See architecture §4.

---

## Revised Requirements

| ID | Requirement | Source defect | Architecture section |
|---|---|---|---|
| R1 | All lock and data operations use a single DataStore key (`TycoonPlayerData_v1`). `TycoonSessionLocks_v1` is not referenced. | D-1 | §1, §2 |
| R2 | The fencing token is generated outside the UpdateAsync callback using `HttpService:GenerateGUID(false)`. The token is a read-only closure capture; it is never mutated inside any callback. | D-3 | §3, §5.2 |
| R3 | Acquisition is confirmed only when `ok==true AND result._session.token==token`. A nil result or token mismatch is treated as confirmed session loss and triggers a kick without retry. | D-3 | §5.4 |
| R4 | The save callback returns nil if `current._session.token ~= token`. Confirmed session loss in savePlayer transitions state to "invalidated" and kicks the player without retry. DataStore errors are retried up to SAVE_RETRIES times. | D-2 | §6 |
| R5 | `invalidated[userId]` is set on initial load failure, confirmed save session loss, confirmed refresh session loss, and persistent refresh failure (elapsed > LOCK_TTL). `getData` checks `invalidated[userId]` and returns nil if set. | D-4 | §9 |
| R6 | The refresh callback verifies `current._session.token == sessionTokens[userId]` and returns nil on mismatch. A nil result transitions state to "invalidated" and kicks the player. | D-5 | §7 |
| R7 | `playerState[userId]` state machine governs all per-player operations. `addCash`/`spendCash` require state "active". `savePlayer` (autosave path) requires state "active" only — rejects "disconnecting" and all other states. `disconnectSave` requires state "disconnecting" (called only from `disconnectPlayer`). The "releasing" state does not exist in the current design; it was removed in Revision 5. | Arch issue | §4, §6.1, §6.5 |
| R8 | A concurrent second `loadPlayer` call for the same player (state "loading" or non-nil) is rejected immediately with a warning. It does not acquire, overwrite, or modify any existing session. | Arch issue | §5.1 |
| R9 | A same-server session in the acquisition callback is treated as an idempotent retry **only** when `current._session.token == token`. If `current._session.jobId == JOB_ID` but `current._session.token ~= token`, the callback returns nil (another invocation on this server holds the session). | Arch issue (Issue 2) | §5.3 |
| R10 | `_session` metadata is never present in `loadedData[userId]` or in the value returned by `getData`. It is stripped at load time and reconstructed from `current._session` inside the save callback. | Existing requirement | §2, §5.6, §6.2 |
| R11 | Legacy records without `_session` are treated as available for acquisition. All existing game fields are preserved. `_session` is added to the record on first load without overwriting any other field. | Existing requirement | §12 |
| R12 | A new player (no prior DataStore record) is initialized from `DEFAULT_DATA`. An existing player whose load fails (all retries exhausted, or confirmed session loss at load time) is kicked without being initialized as a new player. `loadedData[userId]` is never populated on failure. | Existing requirement | §5.5 |
| R13 | `savePlayer` deep-copies `loadedData[userId]` into a local `snapshot` before the `UpdateAsync` call. The callback uses only `snapshot` and the captured `token` — both are immutable from that point forward. The callback does not read `loadedData`, `sessionTokens`, or any other shared mutable table. | D-6 | §6.1, §6.2 |
| R14 | The acquisition callback uses a single TTL-based availability rule: a session is available if absent, released, or `(now - sess.since) >= LOCK_TTL`. A live session is blocked if and only if `sess.token ~= token`. The job ID is not independently evaluated for blocking. | D-7 | §5.3 |
| R15 | `refreshSession` treats any non-error `UpdateAsync` result where `result._session.token ~= sessionTokens[userId]` as confirmed ownership loss, including both `result == nil` and a non-nil result with a different token. Only `result._session.token == sessionTokens[userId]` constitutes a confirmed refresh. | D-8 | §7.2 |
| R16 | `inFlightSaves[userId]` tracks the count of active `savePlayer` UpdateAsync calls. It is incremented before each UpdateAsync and decremented unconditionally after. `disconnectPlayer` confirms `inFlightSaves[userId] == 0` before starting the disconnect save and before calling `releaseSession`. | D-9, D-11 | §8.1, §10.1 |
| R17 | `releaseSession` is called only from `disconnectPlayer` after `inFlightSaves[userId] == 0` is confirmed. If the drain or save deadline is exceeded, `releaseSession` is not called. State transitions to "abandoned" and the session expires by TTL. Release is never attempted while saves remain in flight. | D-10 | §8, §10.1 |
| R18 | `disconnectPlayer(userId, player)` is the single entry point for all disconnect logic. A `shuttingDown[userId]` flag ensures only one caller (PlayerRemoving or BindToClose) owns the drain→save→release lifecycle. The second caller returns immediately without starting any saves or releases. | D-12 | §10 |
| R19 | State table cleanup (`loadedData`, `invalidated`, `lastRefresh`, `inFlightSaves`, `shuttingDown`) is performed only after all async operations have completed. `inFlightSaves[userId]` is not cleared while an in-flight autosave is still running (drain-timeout path). | D-11 | §10.1 |
| R20 | `UpdateAsync` return value when callback returns nil is not confirmed. No code path or test asserts either return behaviour as fact. Both `result == nil` and `result._session.token ~= token` are treated as ownership loss across all four operations (acquire, save, refresh, release). | Revision 5 | §15 Risk 1 |

---

## Defects Found in Revision 3 Architecture (7aa733d)

### D-6: Save callback reads `loadedData[userId]` during UpdateAsync retry (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

The revision 3 save callback reads `loadedData[userId]` inside the UpdateAsync callback:

```lua
newRecord = deepCopy(loadedData[userId])
```

The UpdateAsync callback can be retried by Roblox. If `releaseSession` runs while the callback is mid-execution and clears `loadedData[userId]`, the retry sees `loadedData[userId] == nil` and either errors or writes a nil record.

**Fix:** Deep-copy `loadedData[userId]` into a local `snapshot` variable **before** the UpdateAsync call. The callback uses only `snapshot` and `token` — both immutable after capture. See architecture §6.1–6.2 (Revision 4).

---

### D-7: Acquisition callback has contradictory same-jobId handling (HIGH)

**File:** `PlayerDataManager.lua` (design)

Revision 3 §5.3 had two independent guards — an `anotherServer` check and a `same-server different-token` check — that could produce contradictory results. Specifically:
- §5.3 unconditionally rejected `sess.jobId == JOB_ID, sess.token ~= token`
- Test scenario DS-3 expected an expired same-jobId session to be acquirable

An expired session that happens to share the same job ID (normal in Studio) would be rejected by the same-server guard even though the TTL had expired.

**Fix:** Replace the two independent guards with a single TTL-based rule. A session is available if it is absent, explicitly released, or has `(now - sess.since) >= LOCK_TTL`. A live session (`TTL not expired`) is blocked if and only if `sess.token ~= token`. The job ID is not evaluated separately. See architecture §5.3 (Revision 4).

---

### D-8: `refreshSession` did not handle non-nil wrong-token result (HIGH)

**File:** `PlayerDataManager.lua` (design)

Revision 3 §7.2 handled `result == nil` as ownership loss but did not handle the case where `UpdateAsync` returns the existing DataStore record (another server's token) rather than nil when the callback returns nil. In that case, `result._session.token ~= sessionTokens[userId]` but the code did not reach the ownership-loss branch.

**Fix:** Treat any `ok==true` result where `result._session.token ~= sessionTokens[userId]` as ownership loss. Both `result==nil` and wrong-token non-nil now share the same `else` path. See architecture §7.2 (Revision 4).

---

### D-9: No mechanism to wait for in-flight saves before releasing (HIGH)

**File:** `PlayerDataManager.lua` (design)

Revision 3 `releaseSession` cleared `sessionTokens` to block new saves, but did not wait for saves already in-flight. If the release UpdateAsync was serialized by DataStore before an in-flight save's UpdateAsync, the release would mark the session as released, and then the in-flight save's callback would see `current._session.released == false` (the pre-release state cached by Roblox) and re-write the data record, temporarily removing the `released=true` flag.

Additionally, two concurrent saves with different snapshots (autosave + PlayerRemoving save) can produce a last-DataStore-write-wins race where the older snapshot overwrites the newer one.

**Fix:** Add `inFlightSaves[userId]` counter. `savePlayer` increments it before UpdateAsync and decrements it after. `releaseSession` waits for `inFlightSaves[userId] == 0` (5-second deadline) before proceeding to its own UpdateAsync. This guarantees the final save is committed before the release. See architecture §8.1 (Revision 4).

---

## Summary of Changes from Revision 2 (88d7ff1)

| Issue | Revision 2 problem | Revision 3 fix |
|---|---|---|
| Issue 1 — closure mutation | `sessionVerified = true` set inside UpdateAsync callback; persistent across retries | Removed. Success verified exclusively from `result._session.token == token` after pcall returns |
| Issue 2 — same-server idempotency | `current._session.jobId == JOB_ID` allowed re-acquisition regardless of token | Idempotent retry only when `current._session.token == token`. Different token + same jobId → abort |
| Issue 3 — mutation after ownership loss | `loadFailed` did not block `getData`; `addCash`/`spendCash` could mutate stale data | `invalidated[userId]` checked in `getData`; covers load failure AND mid-game session loss |
| Issue 4 — save/release coordination | No formal lifecycle; `sessionTokens` clear did not prevent concurrent release calls | `playerState[userId]` state machine; "releasing" state blocks duplicate releases; in-flight saves use captured token |

## Defects Found in Revision 4 Architecture (4ec3797)

### D-10: Release proceeded after drain timeout, violating ordering guarantee (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

Revision 4 §8.1 warned when `inFlightSaves > 0` after the 5-second deadline but then proceeded with the release UpdateAsync anyway. The stated ordering guarantee was "saves must commit before release." Proceeding with release while a save was still in-flight violated that guarantee: the release UpdateAsync could be serialised in DataStore before the late save, and the late save's callback would then run after `released=true` was written.

**Actual risk of late save with Revision 4's callback:** The save callback does `newRecord._session = current._session`, copying `current._session` from DataStore. If the release had already committed `released=true`, the late save's callback would see `current._session.released=true` and copy it into the new record. So `released=true` would be preserved. The actual risk was not session re-opening but stale snapshot overwriting newer data, and the session being unavailable to other servers until the late save committed (since another server's acquisition callback would see `released=false` from the stale current record until the late save ran).

**Fix:** When the drain deadline is exceeded, do NOT proceed with the release UpdateAsync. Set state to "abandoned". The session expires by TTL (activeLocks cleared → no refreshes → LOCK_TTL countdown). See architecture §10.1 (Revision 5).

---

### D-11: Cleanup cleared `inFlightSaves[userId]` while save was still in flight (HIGH)

**File:** `PlayerDataManager.lua` (design)

Revision 4 `PlayerRemoving` unconditionally cleared `inFlightSaves[userId] = nil` at the end of cleanup, even in the drain-timeout path where an autosave was still in flight. The in-flight autosave would later try to decrement `inFlightSaves[userId]` — which was now nil — resulting in a nil arithmetic error.

**Fix:** In the drain-timeout TTL path, do NOT clear `inFlightSaves[userId]`. The in-flight autosave owns its counter slot and decrements it itself when its UpdateAsync completes. Only clear `inFlightSaves[userId]` after confirming it is 0 (normal path) or after deliberately giving up on a stuck save (save-deadline path with explicit warning). See architecture §10.1 (Revision 5).

---

### D-12: Both PlayerRemoving and BindToClose could start competing saves (HIGH)

**File:** `PlayerDataManager.lua` (design)

Revision 4 had both `PlayerRemoving` and `BindToClose` independently calling `savePlayer` and `releaseSession`. There was no mechanism to prevent both from starting saves before either called `releaseSession`. The `inFlightSaves` counter would reach 2, and `releaseSession` (called from whichever thread first acquired the "releasing" state) would wait for both — but the two snapshots could differ, and the last-DataStore-write-wins would not necessarily be the more recent snapshot.

**Fix:** Introduce `disconnectPlayer(userId, player)` with a `shuttingDown[userId]` single-ownership guard. The first caller (PlayerRemoving or BindToClose) owns the entire lifecycle (drain → save → release). The second caller returns immediately. Only one save is ever started per disconnect. See architecture §10 (Revision 5).

---

### D-13: IW-1 test scenario incorrectly described late-save risk (DOCUMENTATION)

**File:** `test-results.md` (Revision 4)

Scenario IW-1 stated that a late save would "re-write `released=false`", which is incorrect. The Revision 4 save callback copies `current._session` from DataStore, not from memory. If the DataStore record already has `released=true`, the late save's callback would copy that field and the written record would also have `released=true`. The session would not be re-opened.

The actual risks of allowing a late save were: (a) stale snapshot overwrites newer data written to DataStore by the release, (b) another server's acquisition callback sees a non-released record from the stale `current` passed to the late save callback before it commits, potentially delaying that server's acquisition.

**Fix:** Correct the IW-1 scenario to describe the accurate risk. See test-results.md (Revision 5).

---

## Summary of Changes from Revision 3 (7aa733d)

| Issue | Revision 3 problem | Revision 4 fix |
|---|---|---|
| D-6 — save callback reads shared state | Callback read `loadedData[userId]` during UpdateAsync; could see nil on retry after releaseSession clears it | `snapshot = deepCopy(loadedData[userId])` captured before UpdateAsync; callback uses only snapshot + token |
| D-7 — acquisition contradiction | Same-jobId rejection was unconditional; contradicted test DS-3 for expired sessions | Single TTL rule: session available if expired or released; live sessions blocked only by token mismatch |
| D-8 — refresh non-nil wrong-token | Only checked `result == nil` for ownership loss; missed non-nil result with wrong token | All `ok==true` outcomes where `result._session.token ~= sessionTokens[userId]` treated as ownership loss |
| D-9 — no in-flight save wait | `releaseSession` did not wait for in-flight saves; release could be serialized before save in DataStore | `inFlightSaves[userId]` counter; `disconnectPlayer` confirms counter is 0 before saving and before releasing |

## Summary of Changes from Revision 4 (4ec3797)

| Issue | Revision 4 problem | Revision 5 fix |
|---|---|---|
| D-10 — release after drain timeout | `releaseSession` proceeded even when drain deadline exceeded; violated ordering guarantee | TTL path: if deadline exceeded, do NOT call `releaseSession`; state→"abandoned"; session expires by TTL |
| D-11 — cleanup cleared in-flight counter | `inFlightSaves[userId]=nil` cleared unconditionally in cleanup, even with in-flight autosave | Only clear `inFlightSaves` after confirmed 0 (normal path) or after deliberate give-up (save-deadline path) |
| D-12 — competing saves from both callers | Both PlayerRemoving and BindToClose could independently call `savePlayer`, creating overlapping saves | `disconnectPlayer` with `shuttingDown[userId]` single-owner guard; second caller is a no-op |
| D-13 — IW-1 inaccurate risk description | Claimed late save would write `released=false`; callback actually copies `current._session` preserving `released=true` | Corrected IW-1 to describe actual risks: stale snapshot, delayed acquisition by other servers |

---

## Defects Found in Revision 5 Architecture (fb02581)

### D-14: `savePlayer` guards reject the disconnect save (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

In Revision 5 §6.1, `savePlayer` accepted state `"active"` or `"releasing"`. In §10.1, `disconnectPlayer` set state to `"disconnecting"` and cleared `sessionTokens[userId]` before calling `savePlayer(player)`. This caused both guards to reject the call:

1. **State guard:** `playerState[userId] == "disconnecting"` — not `"active"` or `"releasing"` → `return false`
2. **Token guard:** `sessionTokens[userId] == nil` → `return false`

The result: the final disconnect save was silently skipped. All normal-path timelines (Timelines A and B in §10.4) claiming a successful final save were invalid. Data written since the last autosave would be lost, and no `releaseSession` call would be issued because `savePlayer` returned false before `disconnectPlayer` reached that step.

**Additional issue:** The `"releasing"` state referenced in the §6.1 guard and §9.2 guard does not exist in the Revision 5 state machine. It was replaced by `"disconnecting"` in Revision 5 but the guards were not updated. This meant even a hypothetical correct path could not use the "releasing" state, which was no longer defined.

**Fix:** Introduce `disconnectSave(userId, player, token, snapshot)` as a new internal function that:
- Accepts only `"disconnecting"` state (checked explicitly)
- Uses explicitly passed `token` and `snapshot` (not read from shared state tables)
- May only be called from `disconnectPlayer` after drain completes
- Uses the same UpdateAsync callback structure as `savePlayer`
- Returns `true` on success; on confirmed session loss, sets state to `"abandoned"` and returns `false`

`disconnectPlayer` calls `disconnectSave(userId, player, token, snapshot)` instead of `savePlayer(player)`. The snapshot is taken after the drain completes. The token is the value captured from `sessionTokens` before it was cleared. `savePlayer` is updated to accept `"active"` state only (removing the now-removed `"releasing"` reference). See architecture §6.5 and §10.1 (Revision 6).

---

## Revised Requirements (additions)

| ID | Requirement | Source defect | Architecture section |
|---|---|---|---|
| R21 | `disconnectSave(userId, player, token, snapshot)` is an internal function called only from `disconnectPlayer`, only in `"disconnecting"` state, only after `inFlightSaves[userId] == 0` is confirmed by drain. It uses explicitly passed `token` and `snapshot` (not `sessionTokens` or `loadedData`). It is the only save operation permitted in `"disconnecting"` state. Regular autosaves (`savePlayer`) reject `"disconnecting"` immediately via the state guard in §6.1. | D-14 | §6.5, §10.1 |

---

## Summary of Changes from Revision 5 (fb02581)

| Issue | Revision 5 problem | Revision 6 fix |
|---|---|---|
| D-14 — savePlayer rejects disconnect save | `disconnectPlayer` set state→"disconnecting" and cleared `sessionTokens` before calling `savePlayer`; both guards rejected it → no save, no release | `disconnectSave(userId, player, token, snapshot)` accepts "disconnecting" state and uses explicit token+snapshot; `disconnectPlayer` calls it after drain with captured token and post-drain snapshot |
| "releasing" state references | §6.1 and §9.2 guards referenced non-existent "releasing" state; also R7 described it as valid | Removed all "releasing" references; `savePlayer` accepts "active" only; `getData` checks "active" only; R7 updated |
| In-flight refresh TTL extension | Abandoned-path timelines described TTL countdown starting from activeLocks clear | Documented in §7.5 and Risk 8: TTL countdown starts from last `_session.since` DataStore write, which may be later than activeLocks clear if a refresh was in-flight when disconnect began |

---

## Defects Found in Revision 6 Architecture (9a640fc)

### D-15: `refreshSession` callback reads `sessionTokens[userId]` live — race with disconnect (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

In Revision 6, §7.1 showed the refresh callback comparing `current._session.token ~= sessionTokens[userId]` (reading the shared mutable table directly). §7.2 captured a local `token = sessionTokens[userId]` before the `UpdateAsync` call, but the **callback** did not use that captured value.

This created a race:

1. `refreshSession` starts, capturing `local token = sessionTokens[userId]` (= T_A).
2. The callback is constructed — but its body reads `sessionTokens[userId]` live, not the captured `token`.
3. `disconnectPlayer` runs, sets `sessionTokens[userId] = nil`.
4. The callback is retried by Roblox.
5. Inside the retry: `current._session.token ~= sessionTokens[userId]` → `T_A ~= nil` → true → callback returns nil.
6. §7.2 result handler: `result == nil` → `playerState[userId] = "invalidated"` + kick.
7. `disconnectSave` requires `playerState[userId] == "disconnecting"` → state is now `"invalidated"` → returns false.
8. Final disconnect save is skipped. Session is abandoned without saving. Player is kicked mid-disconnect.

**Additional issue:** Even with a correctly captured token, the §7.2 result handler always set `"invalidated"` and kicked the player on nil result — without checking whether the player was already in `"disconnecting"` state. This meant any ownership-loss signal during a disconnect (even legitimate ones) would fight with the disconnect lifecycle.

**Fix:**
1. §7.1 callback must use the captured `token` (not live `sessionTokens[userId]`). The comment in §7.1 is explicit: "token is a captured read-only local."
2. §7.2 result handler: before transitioning to `"invalidated"`, check `playerState[userId] ~= "active"`. If the player is in `"disconnecting"` or any post-disconnect state, return false without modifying `playerState` or kicking.
3. §7.3 persistent failure: apply the same state guard before transitioning to `"invalidated"`.

See architecture §7.1, §7.2, §7.3 (Revision 7).

---

## Revised Requirements (Revision 7 additions)

| ID | Requirement | Source defect | Architecture section |
|---|---|---|---|
| R22 | The `refreshSession` callback must capture `token = sessionTokens[userId]` once in the outer function before the `UpdateAsync` call and use that captured value inside the callback. The callback must not read `sessionTokens[userId]` directly. The §7.2 result handler and §7.3 persistent-failure handler must each check `playerState[userId] == "active"` before transitioning to `"invalidated"` or kicking. If the player is in any other state (`"disconnecting"`, `"released"`, `"abandoned"`, etc.), both handlers must return false without modifying `playerState` or calling `Kick`. | D-15 | §7.1, §7.2, §7.3 |

---

## Summary of Changes from Revision 6 (9a640fc)

| Issue | Revision 6 problem | Revision 7 fix |
|---|---|---|
| D-15 — refresh callback reads sessionTokens live | §7.1 callback read `sessionTokens[userId]` directly; cleared by disconnectPlayer mid-retry → callback returns nil → "invalidated" overwrites "disconnecting" → disconnectSave rejects | §7.1 callback uses captured `token` (read-only local); §7.2 and §7.3 handlers check `playerState == "active"` before invalidating or kicking |
| Stale state description in §4 "abandoned" | "abandoned" only described drain-timeout; did not mention session-stolen path from disconnectSave | Updated to include "session stolen during disconnectSave" |
| Stale §4 cleanup note | Listed only some state tables; said "On PlayerRemoving" | Updated to list all tables (including `inFlightSaves`, `shuttingDown`) and attributed cleanup to `disconnectPlayer` |
| Stale §7.5 | Described in-flight refresh risk without addressing whether the refresh would falsely detect ownership loss or overwrite disconnect state | Revised to explain: fixed callback prevents false ownership loss; state guard prevents "invalidated" overwrite; TTL-extension risk remains in abandoned path only |

---

## Defects Found in Revision 7 Architecture (6ff285d)

### D-16: Stale refresh operation invalidates a newer session for the same userId (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

Revision 7 §7.2 and §7.3 guard refresh result handling with a single check:

```
if playerState[userId] ~= "active": return false
```

This is insufficient. A player can disconnect (session T_A), and the same server cleans up and accepts a rejoin (session T_B, state → "active"). An old `refreshSession` task from T_A that was in-flight during the disconnect captured `local token = T_A` and is now completing. With T_B active, `playerState[userId] == "active"` — the state guard passes. The handler then proceeds to invalidate the current session:

1. T_A session disconnects fully. `disconnectPlayer` cleanup: `playerState[userId]` left as `"released"` (not cleared to nil).
2. `loadPlayer` check: `playerState[userId] ~= nil` → **loadPlayer rejects the rejoin** ← separate contradiction (see below).

   _If playerState were cleared to nil_ (the §4/§10.1 contradiction fix):
3. Player rejoins: `playerState[userId] == nil` → `loadPlayer` allowed. T_B: state → "active", `sessionTokens[userId] = T_B`.
4. Old T_A refresh completes. `result == nil` or `result._session.token == T_B ≠ T_A`.
5. §7.2 handler: `playerState[userId] == "active"` → state guard passes.
6. `playerState[userId] = "invalidated"`, `invalidated[userId] = true`, player kicked.
7. T_B session is destroyed by a T_A refresh result. **Data loss; player incorrectly kicked.**

**Additional issue — cleanup contradiction:**

§4 cleanup note says `playerState` is cleared after disconnect, but §10.1 cleanup code sets `playerState` to `"released"` or `"abandoned"` without also clearing it to nil. `loadPlayer` §5.1 rejects any non-nil `playerState`. Therefore, after a session disconnects, `loadPlayer` always rejects a rejoin on the same server — the player can never rejoin the same server instance. This contradicts the design intent (TTL path, same-server rejoins, Studio testing).

**Additional issue — BindToClose `disconnectCount` premature decrement:**

§10.3 BindToClose spawns a task per player that calls `disconnectPlayer` and then decrements `disconnectCount`. If `PlayerRemoving` has already set `shuttingDown[userId] = true`, the BindToClose spawn's `disconnectPlayer` call returns immediately (single-owner guard), and `disconnectCount -= 1` fires before the actual lifecycle is complete. BindToClose's wait loop can reach 0 and exit while `PlayerRemoving` is still running saves.

**Fix:**

1. **§7.2 and §7.3 dual identity check:** Before applying any refresh result to per-player state (whether success, failure, or TTL-expiry), verify BOTH: `playerState[userId] == "active"` AND `sessionTokens[userId] == token` (the captured value). If either fails, the refresh belongs to a stale session; return false without modifying any state.

2. **§10.1 cleanup:** All three cleanup paths (normal, drain-timeout, save-failed) must explicitly set `playerState[userId] = nil` before returning. The drain-timeout path is special: `playerState` is left as `"abandoned"` temporarily so that `loadPlayer` knows a rejoin is not yet safe. When the stalled autosave eventually completes and `inFlightSaves` reaches 0 in §6.3, `savePlayer` must check if `playerState == "abandoned"` and clear it to nil at that point.

3. **§10.3 BindToClose observe-and-wait:** When `disconnectPlayer` observes `shuttingDown[userId]` already set by another caller, it must loop-wait (`while shuttingDown[userId] do task.wait(0.05) end`) before returning. This ensures `disconnectCount -= 1` fires only after the owner's cleanup is complete.

See architecture §7.2, §7.3, §10.1, §10.3 (Revision 8).

---

## Revised Requirements (Revision 8 additions)

| ID | Requirement | Source defect | Architecture section |
|---|---|---|---|
| R23 | The §7.2 result handler and §7.3 persistent-failure handler must each check BOTH `playerState[userId] == "active"` AND `sessionTokens[userId] == token` (the captured value) before transitioning to `"invalidated"` or kicking. If either check fails, the refresh belongs to a stale session and must return false without modifying `playerState`, `invalidated`, `lastRefresh`, or calling `Kick`. The same dual check applies to the successful refresh path before updating `lastRefresh[userId]`. | D-16 | §7.2, §7.3 |
| R24 | All `disconnectPlayer` cleanup paths must explicitly clear `playerState[userId] = nil` as the final cleanup step, to enable a legitimate rejoin on the same server. Exception: the drain-timeout path clears `playerState` to nil only after the stalled autosave's `inFlightSaves` decrement reaches 0 in §6.3 (i.e., `savePlayer` clears `playerState[userId]` when `inFlightSaves` hits 0 and `playerState == "abandoned"`). At no other point may `playerState` be left as a non-nil terminal state after all async operations for the old session are complete. | D-16 | §4, §10.1 |
| R25 | When `disconnectPlayer` detects that `shuttingDown[userId]` is already `true` (another caller owns the lifecycle), it must loop-wait (`while shuttingDown[userId] do task.wait(0.05) end`) before returning. This ensures that `BindToClose`'s `disconnectCount -= 1` fires only after the actual lifecycle completes, not when the observing caller returns early. The wait exits when the owner clears `shuttingDown[userId] = nil` in its cleanup. | D-16 | §10.3 |

---

## Summary of Changes from Revision 7 (6ff285d)

| Issue | Revision 7 problem | Revision 8 fix |
|---|---|---|
| D-16 — stale refresh invalidates new session | §7.2/§7.3 guarded only on `playerState == "active"`; a rejoin T_B could be active while old T_A refresh completes → T_B session invalidated/kicked | Dual identity check: `playerState == "active"` AND `sessionTokens[userId] == capturedToken` both required; stale T_A refresh returns false on second check |
| §4/§10.1 cleanup contradiction | §4 said playerState is cleared; §10.1 set it to "released"/"abandoned" but never nil'd it; §5.1 rejects non-nil playerState → rejoin always blocked | §10.1 cleanup explicitly clears `playerState[userId] = nil`; drain-timeout path defers clear to §6.3 after autosave completes |
| BindToClose disconnectCount premature decrement | Second caller's `disconnectPlayer` returned immediately (shuttingDown guard); `disconnectCount -= 1` fired before lifecycle complete; BindToClose could exit early | Observing caller waits on `shuttingDown` before returning; counter only decremented after real completion |

---

## Defects Found in Revision 8 Architecture (3464ec5)

### D-17: BindToClose completion still premature during drain timeout (CRITICAL)

**File:** `PlayerDataManager.lua` (design)

Revision 8 §10.1 drain-timeout path clears `shuttingDown[userId] = nil` while `inFlightSaves[userId]` is still > 0 (the autosave is in flight). The Revision 8 fix added a Phase-1 wait (`while shuttingDown`) for observing callers. When `shuttingDown` clears, the observer returns and `disconnectCount -= 1` fires — but the autosave has not completed. BindToClose may therefore exit its wait loop and return before the autosave commits.

**Example:** PlayerRemoving starts disconnect; drain times out after 5s; `shuttingDown[X]=nil` cleared; BindToClose observer exits Phase-1; `disconnectCount` goes to 0; BindToClose outer loop exits; server shuts down with autosave still in flight.

**Fix:** Observing caller's wait must be two-phase:
1. Phase 1: `while shuttingDown[userId] do task.wait(0.05) end` — wait for lifecycle owner to exit
2. Phase 2: `while (inFlightSaves[userId] or 0) > 0 do task.wait(0.05) end` — wait for all outstanding saves

`disconnectCount -= 1` fires only after both phases. In the normal path, Phase 2 passes immediately (`inFlightSaves` was cleared to nil in step 7 cleanup). In the drain-timeout path, Phase 2 blocks until the autosave commits. The BindToClose 25-second outer deadline provides the escape hatch if Phase 2 never completes.

See architecture §10.1, §10.3 (Revision 9).

---

### D-18: Async operation tracking is incomplete and undocumented (HIGH)

**File:** `PlayerDataManager.lua` (design)

The design explicitly tracks saves with `inFlightSaves`, but `refreshSession` tasks can also be in flight during and after disconnect. Revision 8 did not explicitly categorize which operations must drain and which may safely outlive cleanup. This creates ambiguity: can BindToClose claim all async operations are done when `inFlightSaves == 0`? The answer is yes — but only if refresh tasks are explicitly justified as safe to leave in flight.

**Categorization (Revision 9 clarification):**

- **Autosave UpdateAsync (`savePlayer`):** tracked by `inFlightSaves`; must drain before BindToClose returns. Safety: captured immutable token+snapshot; callback does not read shared state.
- **Disconnect save UpdateAsync (`disconnectSave`):** `inFlightSaves[userId] = 1` while running; synchronous within lifecycle (completes before owner clears `shuttingDown`). Safety: same captured-token pattern.
- **Release UpdateAsync (`releaseSession`):** synchronous within lifecycle; completes before owner clears `shuttingDown`. Not tracked by `inFlightSaves`.
- **Refresh tasks (`refreshSession` UpdateAsync):** not tracked by `inFlightSaves`; may safely outlive cleanup. Safety: dual identity check in §7.2/§7.3 — stale T_A refresh cannot modify T_B session state. BindToClose does not need to track these.

**Why refresh tasks are not tracked:** Refresh tasks are fire-and-forget (spawned on 20s cycle). Adding a counter would require coordination across the refresh loop and `disconnectPlayer`. The dual identity check provides the same correctness guarantee without that complexity. The tradeoff is accepted: a refresh task may still be running when the server shuts down, but it cannot corrupt per-player state.

See architecture §10.1 D-18 discussion (Revision 9).

---

### D-19: Contradictory shutdown documentation — "returns immediately" vs "waits for owner" (DOCUMENTATION)

**File:** `PlayerDataManager.lua` (design)

The opening paragraph of §10 (Revision 8) states: "A `shuttingDown[userId]` flag ensures only one caller owns the lifecycle; the other returns immediately without competing saves or releases."

§10.3 (Revision 8) corrects this for the BindToClose case: "It loops on `shuttingDown[userId]`..."

Timelines C and D (Revision 8) showed the observer looping, which was correct. But the §10 introduction still said "returns immediately," creating a contradiction in the same document.

**Fix:** §10 introduction updated to: "The second (observing) caller does not return immediately — it waits for the owner to complete all outstanding operations before returning." All timelines and pseudocode are consistent with this. See architecture §10 (Revision 9).

---

## Revised Requirements (Revision 9 additions)

| ID | Requirement | Source defect | Architecture section |
|---|---|---|---|
| R26 | The observing caller in `disconnectPlayer` must perform a two-phase wait before returning: (1) wait for `shuttingDown[userId]` to clear (lifecycle owner has exited), then (2) wait for `(inFlightSaves[userId] or 0) == 0` (all tracked saves complete). `disconnectCount -= 1` in BindToClose fires only after both phases. In the normal path, Phase 2 passes immediately. In the drain-timeout path, Phase 2 blocks until the stalled autosave commits or the BindToClose 25-second outer deadline fires. | D-17 | §10.1 (step 1 pseudocode), §10.3 |
| R27 | The design must explicitly document which async operations are tracked by `inFlightSaves`, which may safely outlive cleanup, and what prevents untracked operations from corrupting newer sessions. Saves (`savePlayer`, `disconnectSave`, `releaseSession`) must drain before BindToClose returns. Refresh tasks (`refreshSession`) are exempt from tracking because the dual identity check in §7.2/§7.3 prevents them from modifying any state belonging to a different session. | D-18 | §10.1 D-18 discussion, §10.3 |

---

## Summary of Changes from Revision 8 (3464ec5)

| Issue | Revision 8 problem | Revision 9 fix |
|---|---|---|
| D-17 — BindToClose premature completion during drain-timeout | Observing caller's Phase-1 wait exited when shuttingDown cleared; autosave still in flight; disconnectCount decremented prematurely | Two-phase wait: Phase 1 (shuttingDown), then Phase 2 (inFlightSaves == 0); counter decremented only after both phases |
| D-18 — async operation tracking undocumented | No explicit statement of which operations must drain vs may safely outlive cleanup | §10.1 table: saves tracked/must drain; refresh tasks untracked/safe to outlive (dual identity check justification) |
| D-19 — contradictory §10 introduction | §10 intro said "other returns immediately"; §10.3 and timelines showed waiting | §10 intro corrected to describe two-phase wait; all timelines consistent |
