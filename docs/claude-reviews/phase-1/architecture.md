# Phase 1 Architecture — Cash Empire Tycoon (Revision 14)

**Date:** 2026-11-25
**Scope:** `PlayerDataManager.lua` session locking design
**Status:** Revision 14 — pending approval before implementation

---

## 1. Design Principle

Every lock check and every data write must be atomic operations on a single DataStore key.

The initial design stored the session lock (`TycoonSessionLocks_v1`) and player data (`TycoonPlayerData_v1`) in separate keys. Roblox DataStores provide no cross-key atomic operations. That two-DataStore architecture made it impossible to verify lock ownership at write time, regardless of how correctly the lock was acquired beforehand.

The revised design embeds `_session` metadata directly inside the `TycoonPlayerData_v1` record. `TycoonSessionLocks_v1` is removed entirely. Every meaningful operation (acquire, save, refresh, release) is a single `UpdateAsync` on the player's one key.

---

## 2. On-Disk Record Format

```
TycoonPlayerData_v1[tostring(userId)]
─────────────────────────────────────────────────────
{
    _session = {
        jobId    : string,   -- game.JobId of owning server (or studio fallback)
        token    : string,   -- UUID from HttpService:GenerateGUID(false)
        since    : number,   -- os.time() when session was last confirmed (refresh or acquire)
        released : boolean,  -- true when session was explicitly released
    },
    Cash               : number,
    TotalEarned        : number,
    PrestigeLevel      : number,
    PrestigeMultiplier : number,
    UnlockedUpgrades   : array,
    StarterPackClaimed : boolean,
    RedeemedCodes      : table,
    GroupBonusClaimed  : boolean,
    Gamepasses         : table,
}
```

**Legacy records** (all existing players) have no `_session` field. The absence of `_session` is treated identically to a released session — available for acquisition.

**`_session` is never exposed to game logic.** It is stripped before `loadedData[userId]` is populated. It is never present in the table returned by `getData`. It is restored from `current._session` inside the save callback — never from memory.

---

## 3. Fencing Token

A fencing token is a string that proves "my specific load invocation wrote this record."

**Generation:** `game:GetService("HttpService"):GenerateGUID(false)`. This produces a 36-character RFC 4122 UUID. It is generated once per `loadPlayer` call, **outside the UpdateAsync callback**, before the callback is constructed. The callback captures the token as a read-only closure variable and never mutates it.

**Association with one session:** The token is specific to the tuple `(userId, server instance, loadPlayer invocation)`. It is stored in `sessionTokens[userId]` only after confirmed acquisition. If the same player loads again on the same server, a new token is generated and the old session must be verified to be unambiguously the current invocation's (see §5.2).

**Studio fallback:** `HttpService:GenerateGUID(false)` does not require HTTP requests to be enabled — confirmed by its absence of a `Network` capability in the official Roblox documentation (the function carries only a `Write Parallel` tag, indicating it is a purely local UUID generation operation). The `pcall` is included as defensive programming only; the fallback `tostring(math.random(1e15)) .. "_" .. JOB_ID` is weaker but sufficient. The fallback is not expected to execute in practice. See §15 Risk 3 (downgraded to non-issue).

---

## 4. Per-Player Lifecycle State Machine

Every player has an explicit lifecycle state tracked in `playerState[userId]`. All operations check and transition this state. This is the coordination mechanism for in-flight saves, concurrent loads, and release races.

```
            [nil / "idle"]
                  │ loadPlayer starts
                  ▼
           ["loading"]
           /           \
   load succeeds     load fails (all retries)
          │                    │
          ▼                    ▼
       ["active"]          ["failed"] ──── terminal
       /      \
session loss   disconnectPlayer called
      │              │
      ▼              ▼
["invalidated"]  ["disconnecting"]
 ─── terminal    /           \
         saves drained      drain deadline exceeded
         + save + release    (session not released)
              │                     │
              ▼                     ▼
         ["released"]          ["abandoned"]
          ── terminal           ── terminal
          (DataStore:           (DataStore: session
           released=true)        expires by TTL)
```

**State definitions:**

| State | Meaning | Allowed operations |
|---|---|---|
| nil / "idle" | Player not loaded | loadPlayer |
| "loading" | loadPlayer in progress | — (concurrent loadPlayer rejected) |
| "active" | Session held; data valid | getData, addCash, spendCash, savePlayer |
| "disconnecting" | Disconnect lifecycle in progress | disconnectSave (called only by disconnectPlayer after drain; uses explicit token+snapshot) |
| "released" | Session explicitly released in DataStore | — (all operations blocked) |
| "abandoned" | Disconnect deadline exceeded, or session stolen during disconnectSave; session expires by TTL | — (all operations blocked) |
| "failed" | Load failed | — (all operations blocked); `PlayerRemoving` triggers terminal cleanup in `disconnectPlayer` (D-21): clears `playerState` and `invalidated` to nil, enables same-server rejoin |
| "invalidated" | Session stolen mid-game | — (all operations blocked); `PlayerRemoving` triggers terminal cleanup in `disconnectPlayer` (D-21): immediate full cleanup if `inFlightSaves == 0`; partial cleanup + `playerState → "abandoned"` if saves remain in flight |

**Transition rules:**

- `nil → "loading"`: start of `loadPlayer`; rejected if state is non-nil
- `"loading" → "active"`: after confirmed acquisition
- `"loading" → "failed"`: after all load retries exhausted
- `"active" → "disconnecting"`: start of `disconnectPlayer`; first caller wins (see §10)
- `"disconnecting" → "released"`: saves drained, disconnect save committed, release UpdateAsync confirmed
- `"disconnecting" → "abandoned"`: drain deadline exceeded; disconnectSave detects session loss; disconnectSave all retries exhausted; or releaseSession all retries exhausted
- `"active" → "invalidated"`: confirmed session loss in `savePlayer` or `refreshSession`, **only when `playerState` is still `"active"` AND `sessionTokens[userId]` still equals the captured token at the time of result verification** — see §7.2 for the dual identity check
- `"released" → nil`: cleared by `disconnectPlayer` step 7 (normal and save-failed paths) after all async operations complete; enables same-server rejoin
- `"abandoned" → nil`: on the save-failed abandoned path, cleared by `disconnectPlayer` step 7; on the drain-timeout abandoned path, deferred to `§6.3 Step 4` (save-completion handler) and cleared only after the last in-flight autosave completes and `inFlightSaves` reaches 0; on the invalidated-PlayerRemoving deferred path (D-21), also cleared by `§6.3 Step 4` after `disconnectPlayer` terminal cleanup transitions `"invalidated" → "abandoned"`
- `"failed" → nil`: on `PlayerRemoving`, `disconnectPlayer` terminal cleanup clears `playerState` and `invalidated` to nil immediately; session was never activated, no async operations are outstanding; enables same-server rejoin (D-21)
- `"invalidated" → nil` (immediate): on `PlayerRemoving` when `(inFlightSaves[userId] or 0) == 0`, `disconnectPlayer` terminal cleanup clears all per-player state to nil immediately; enables same-server rejoin (D-21)
- `"invalidated" → "abandoned"` (deferred): on `PlayerRemoving` when `(inFlightSaves[userId] or 0) > 0`, `disconnectPlayer` terminal cleanup clears `loadedData`, `invalidated`, `activeLocks`, `lastRefresh` to nil and sets `playerState = "abandoned"`; `sessionTokens`, `inFlightSaves`, and `playerState` subsequently cleared by `§6.3 Step 4` when the last in-flight save completes; the remaining in-flight saves will all complete with `confirmedSessionLoss` (session already stolen) and trigger no data writes (D-21)

**Cleanup:** Cleanup ownership differs by path:

- **Normal and save-failed paths:** `disconnectPlayer` step 7 clears all per-player state tables to nil: `playerState`, `loadedData`, `sessionTokens`, `activeLocks`, `lastRefresh`, `inFlightSaves`, `shuttingDown`, `invalidated`.
- **Drain-timeout path:** `disconnectPlayer` clears `loadedData`, `invalidated`, `lastRefresh`, `activeLocks`, and `shuttingDown`, then exits with `playerState = "abandoned"` while in-flight autosaves remain. The final cleanup of `sessionTokens`, `inFlightSaves`, and `playerState` is deferred to `§6.3 Step 4`, which fires from the save-completion handler after the last autosave completes and `inFlightSaves` reaches 0.
- **Terminal state PlayerRemoving path (D-21):** `disconnectPlayer` handles `"failed"` and `"invalidated"` states when `PlayerRemoving` fires after a failed load or session invalidation:
  - **`"failed"` state:** immediate cleanup — `playerState` and `invalidated` cleared to nil. All other tables are nil (the session was never activated in §5.6; no async operations outstanding).
  - **`"invalidated"` state, `inFlightSaves == 0`:** immediate full cleanup — all per-player state tables cleared to nil. No saves are outstanding.
  - **`"invalidated"` state, `inFlightSaves > 0`:** partial cleanup — `loadedData`, `invalidated`, `activeLocks`, `lastRefresh` cleared to nil; `playerState` transitioned to `"abandoned"`. Remaining in-flight saves will all complete with `confirmedSessionLoss` (session is stolen; no data to write); `§6.3 Step 4` performs final deferred cleanup of `sessionTokens`, `inFlightSaves`, `playerState` when `inFlightSaves` reaches 0. `shuttingDown[userId]` is nil in this path (the disconnect lifecycle was never owned for this player).

`sessionTokens[userId]` is cleared in step 7 (normal and save-failed paths) or by §6.3 (drain-timeout path). It is **not** cleared in step 2 — doing so early would prevent §6.3's dual identity check from verifying which session's save is completing in the drain-timeout path (see D-20).

**Rejoin safety:** `playerState[userId] = nil` after cleanup is what allows `loadPlayer` to accept a rejoin on the same server (§5.1 rejects any non-nil state). The dual identity check in §7.2–7.3 (not playerState alone) is what blocks stale refresh operations from the old session from interfering with the new one.

---

## 5. Session Acquisition (`loadPlayer`)

### 5.1 Concurrent load guard

At the start of `loadPlayer`, check and set `playerState[userId]`:

```
if playerState[userId] ~= nil:
    warn("loadPlayer called for " .. player.Name .. " in state " .. playerState[userId])
    return nil
playerState[userId] = "loading"
```

This prevents two concurrent `loadPlayer` calls for the same player on the same server. No data can be overwritten by a racing second load.

**D-22 caller responsibility — same-player rejoin during active load:** If `loadPlayer` is called while `playerState[userId] == "loading"` (a previous load is in progress, its `UpdateAsync` has not yet returned), it returns nil immediately with a warning. This can occur when the same player triggers `PlayerAdded` a second time before the first load completes — for example, if the player left and quickly rejoined the same server while the first load was still yielded inside `UpdateAsync`. The `PlayerAdded` handler must detect this case and kick the player with a retry message ("Data still loading from a previous session. Please wait and rejoin."). After the original load detects the player has left (§5.6 presence check) and releases the session, the player can successfully join any server.

### 5.2 Fencing token generation

```
token = HttpService:GenerateGUID(false)   -- generated here, once, outside callback
```

### 5.3 Callback logic (pure function; no external state mutation)

The callback reads `current`, applies logic, and returns a new record or nil. It captures `token` and `JOB_ID` as read-only values. It mutates no external variables.

The acquisition decision reduces to a single TTL-based rule: **a session is available if it is absent, explicitly released, or has not been refreshed within LOCK_TTL seconds.** A live session (TTL not expired) is blocked regardless of which server or invocation holds it, unless the token matches this specific invocation (idempotent retry).

```
callback(current):
    now = os.time()

    if current ~= nil and current._session ~= nil:
        sess = current._session
        sessionExpired = (now - (sess.since or 0)) >= LOCK_TTL
        sessionReleased = sess.released == true

        if not sessionExpired and not sessionReleased:
            -- Session is live. Only allow if this invocation's token is already in DataStore.
            if sess.token == token:
                -- Idempotent retry: our write succeeded but the ack was lost.
                -- Re-write the same record. No-op for DataStore state.
                -- (fall through to write below)
            else:
                -- Token does not match. Session is held by another server OR another
                -- loadPlayer invocation on this same server. Either way, abort.
                return nil

    -- Reaching here means: no session, released, TTL expired, or idempotent retry.
    -- Preserve all game fields; write our session token.
    newRecord = {}
    if current ~= nil:
        for k, v in current: if k ~= "_session": newRecord[k] = v

    newRecord._session = { jobId=JOB_ID, token=token, since=now, released=false }
    return newRecord
```

**TTL-expired sessions (any server or invocation):** If the session's `since` is older than LOCK_TTL, the session is considered stale and is available for acquisition. This applies whether the stale session was written by another server (`sess.jobId ~= JOB_ID`) or by a different invocation on this server (`sess.jobId == JOB_ID, sess.token ~= token`). The TTL check is the single governing rule; the job ID is not separately evaluated.

**Live same-server different-token case:** If `(now - sess.since) < LOCK_TTL` and `sess.token ~= token`, the callback returns nil regardless of `sess.jobId`. The concurrent-load guard (§5.1) prevents this from occurring in normal operation on the same server; this branch is a defence-in-depth fallback.

**Idempotent retry:** If `sess.token == token` and the session is live, this invocation's write succeeded previously but the ack was lost. The callback re-writes the same record. The returned result satisfies `result._session.token == token`.

### 5.4 Acquisition verification without closure mutation

After `pcall(UpdateAsync)`:

```
ok, result, _keyInfo = pcall(PlayerStore.UpdateAsync, PlayerStore, userId, callback)
```

**Verification is entirely from the return value. No closure variable is used.**

| `ok` | `result` | Meaning | Action |
|---|---|---|---|
| false | — | DataStore error | Retry with backoff |
| true | `result._session.token == token` | Acquisition confirmed | Proceed |
| true | `result == nil` OR `result._session.token ~= token` | Another server holds session (callback returned nil, or our token was not written) | Kick; do not retry |

**Why result-verification is safe across callback retries:**

Scenario: callback call 1 writes our record (token T_A). Write ack is lost. Meanwhile, Server B acquires the session (token T_B in DataStore). Roblox retries: callback call 2 receives `current._session.token == T_B ≠ T_A` → callback returns nil → `UpdateAsync` returns nil.

Old approach (sessionVerified closure): `sessionVerified = true` from call 1 persists → outer code reports success → WRONG.

New approach (result verification): `result == nil` → outer code correctly reports failure → kick. The final DataStore state (Server B's lock) is correctly reflected.

### 5.5 Load retry logic

```
for attempt = 1 to LOAD_RETRIES (3):
    ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)
    
    if ok and result ~= nil and result._session ~= nil and result._session.token == token:
        break                                -- acquisition confirmed
    
    if ok and (result == nil or result._session.token ~= token):
        playerState[userId] = "failed"
        kick("Your session is active on another server. Please wait and rejoin.")
        return nil                           -- confirmed state; do NOT retry
    
    if not ok:
        warn("load attempt " .. attempt .. "/" .. LOAD_RETRIES)
        if attempt < LOAD_RETRIES and player still in game:
            task.wait(LOAD_BACKOFF * attempt)
        
-- After loop: if no break occurred
playerState[userId] = "failed"
invalidated[userId] = true
kick("Your data could not be loaded. Please rejoin.")
return nil
```

### 5.6 Post-acquisition data construction

```
-- D-22: Verify player is still on this server before activating the session.
-- PlayerRemoving may have fired while UpdateAsync was in progress. The §5.1 guard
-- ensures no concurrent T_B load ran during this window (playerState was "loading"),
-- so the player object below is unambiguously T_A's.
if player.Parent == nil then
    -- Player left while load was in progress. The DataStore session was acquired but
    -- no one remains to use it. Release it immediately to unblock other servers
    -- (instead of waiting LOCK_TTL). Inline release; TTL is the safety net if this fails.
    for attempt = 1, RELEASE_RETRIES do
        local ok, result = pcall(PlayerStore.UpdateAsync, userId, function(current)
            if current == nil or current._session == nil then return nil end
            if current._session.token ~= token then return nil end
            local rec = deepCopy(current)
            rec._session.released = true
            return rec
        end)
        if ok and result ~= nil and result._session ~= nil
                and result._session.token == token and result._session.released == true then
            break
        end
        if not ok and attempt < RELEASE_RETRIES then task.wait(SAVE_BACKOFF * attempt) end
    end
    warn("loadPlayer: player " .. userId .. " left during acquisition; session released.")
    playerState[userId] = nil      -- clear "loading"; allows future loads for this userId
    return nil
end

rawData = all keys from result excluding "_session"

if rawData is empty (no game fields: new player or brand-new key):
    data = deepCopy(DEFAULT_DATA)
else:
    data = deepCopy(DEFAULT_DATA)           -- start from defaults
    for k, v in rawData: merge v into data  -- saved values overwrite defaults

sessionTokens[userId]  = token
activeLocks[userId]    = true
lastRefresh[userId]    = os.time()
loadedData[userId]     = data               -- _session is NEVER in this table
playerState[userId]    = "active"
return data
```

**Ordering invariant for presence check (D-22):** The check (`player.Parent == nil`) runs after confirmed acquisition but **before** session activation. This ensures:

1. If player is gone: the session is released inline; `playerState` is cleared to `"loading" → nil`; `sessionTokens`, `loadedData`, `activeLocks` are never set. A future same-server `loadPlayer` sees nil state and can proceed normally.
2. If player is present: activation proceeds in the normal order (`sessionTokens → activeLocks → lastRefresh → loadedData → playerState → "active"`).

**Limitation:** If the inline release DataStore call fails all retries, the session remains live in DataStore and blocks other servers for up to `LOCK_TTL` (60 s). This is acceptable: the player is gone, the data is consistent (the acquired session was never used), and TTL is the documented safety net.

---

## 6. Save (`savePlayer`)

### 6.1 Guards and immutable snapshot

All values the callback needs must be captured before the UpdateAsync call. The callback must not read any shared mutable state (`loadedData`, `sessionTokens`) because those tables can change while the callback is mid-execution or being retried: `loadedData[userId]` is cleared in the disconnect path; `sessionTokens[userId]` is cleared by step-7 cleanup or overwritten when a new session starts.

`savePlayer` is the **autosave path only**. It accepts state `"active"` exclusively. When `disconnectPlayer` sets state to `"disconnecting"`, all future `savePlayer` calls are rejected immediately at the state guard. The disconnect path uses a separate internal function (`disconnectSave`; see §6.5) that accepts `"disconnecting"` state and receives an explicit token and snapshot from `disconnectPlayer`.

```
if playerState[userId] ~= "active":
    return false                                -- rejects "disconnecting" and all other states
if loadedData[userId] == nil:
    return false

local token    = sessionTokens[userId]   -- captured; valid even if sessionTokens cleared later
if token == nil: return false

local snapshot = deepCopy(loadedData[userId])  -- immutable copy; callback uses this, not loadedData
if snapshot == nil: return false

inFlightSaves[userId] = (inFlightSaves[userId] or 0) + 1
-- ... UpdateAsync call ...
-- (inFlightSaves decremented in §6.3 after the call, success or failure)
```

`snapshot` is a deep copy of the player's in-memory data taken at the moment `savePlayer` is called. It is a local variable captured by the callback closure. `loadedData[userId]` being cleared after this point has no effect on the callback.

### 6.2 Callback (uses only immutable captured values)

The callback uses only `token` (a string) and `snapshot` (a deepCopy) — both captured before the UpdateAsync call, both immutable. It reads nothing from shared mutable state.

```
callback(current):
    if current == nil or current._session == nil:
        return nil                       -- session record gone; abort

    if current._session.token ~= token:  -- token is a captured read-only string
        return nil                       -- session superseded; abort

    newRecord = deepCopy(snapshot)              -- snapshot captured before UpdateAsync
    newRecord._session = current._session       -- session metadata from DataStore, not memory
    return newRecord
```

The callback mutates no external state. `token` and `snapshot` are read-only closure captures.

**Autosaves are serialised by the disconnect lifecycle:** `disconnectPlayer` drains all in-flight autosaves before taking the disconnect snapshot and calling `disconnectSave`. At most one save (autosave or disconnect save) is in-flight at any point during the disconnect lifecycle. The snapshot passed to `disconnectSave` is taken after all autosaves have committed, so it reflects all mutations up to that point. See §10 for the full disconnect lifecycle and §6.5 for `disconnectSave`.

### 6.3 Verification and in-flight save counter

After each `pcall(UpdateAsync)`, success is confirmed only when `result._session.token == token`. Every other non-error outcome — `result == nil` and `result._session.token ~= token` — is treated as confirmed session loss. This covers both possible `UpdateAsync` behaviours when the callback returns nil (see §15 Risk 1).

```
local confirmedSessionLoss = false
local saveSucceeded = false

for attempt = 1 to SAVE_RETRIES:
    local ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)
    
    if ok and result ~= nil and result._session ~= nil and result._session.token == token:
        saveSucceeded = true
        break                                -- confirmed save
    
    if ok:
        -- result == nil (callback returned nil) OR
        -- result ~= nil but result._session.token ~= token (another token in DataStore)
        -- Both indicate ownership loss. Do not retry.
        confirmedSessionLoss = true
        break

    if not ok:
        warn("save attempt " .. attempt .. "/" .. SAVE_RETRIES)
        if attempt < SAVE_RETRIES: task.wait(SAVE_BACKOFF * attempt)

-- Step 1: Decrement (always — this operation owns this counter slot)
inFlightSaves[userId] = math.max(0, (inFlightSaves[userId] or 1) - 1)

-- Step 2: Dual identity check (D-20)
-- sessionTokens[userId] is preserved through disconnectPlayer step 2 (not cleared there),
-- so this check is valid even in the drain-timeout path (playerState == "abandoned").
-- If this check fails, a new session T_B is active; this T_A completion must not touch T_B's state.
if sessionTokens[userId] ~= token:
    return false   -- stale completion; do not modify playerState, invalidated, or kick

-- Step 3: Session-loss handling — state-conditional
if confirmedSessionLoss:
    if playerState[userId] == "active":
        -- Normal autosave path: genuine ownership loss for the currently active session.
        playerState[userId] = "invalidated"
        invalidated[userId] = true
        warn("savePlayer: session ownership lost for userId=" .. userId)
        local livePlayer = Players:GetPlayerByUserId(tonumber(userId))
        if livePlayer then livePlayer:Kick("Your session was claimed by another server.") end
        return false
    else:
        -- State is "disconnecting" or "abandoned": player already leaving / already left.
        -- The DataStore has another server's token, but there is no active player to kick.
        -- Skip invalidation; fall through to drain-timeout cleanup below.
        warn("savePlayer: session ownership lost for userId=" .. userId
             .. " (state=" .. tostring(playerState[userId]) .. "); no kick needed.")

-- Step 4: Drain-timeout cleanup
-- After decrement (Step 1), if state is "abandoned" and counter reached 0, the last in-flight
-- save for this session has completed or failed. Clear session identity and enable rejoin.
-- This is the ONLY point where sessionTokens is cleared in the drain-timeout path.
if playerState[userId] == "abandoned" and inFlightSaves[userId] == 0:
    sessionTokens[userId] = nil      -- clear session identity; kept alive until this point for Step 2
    inFlightSaves[userId] = nil      -- set to nil for consistency with step-7 cleanup (D-20 deep review, M-2)
    playerState[userId] = nil        -- enable same-server rejoin (§5.1 accepts nil state)
    -- loadedData[userId] was already cleared by disconnectPlayer drain-timeout cleanup (§10.1 step 3)
    return saveSucceeded

-- Step 5: Normal autosave completion (state == "active" at save time, still active on return)
if not saveSucceeded:
    warn("savePlayer: all retries exhausted for userId=" .. userId)
return saveSucceeded
```

`confirmedSessionLoss` and `saveSucceeded` are set in the outer loop body, not inside the callback. The in-flight counter is decremented unconditionally in Step 1 so `releaseSession` is never blocked by a save that errored out silently.

**Completion protocol ordering (D-20):**

| Step | Action | Rationale |
|---|---|---|
| 1 — Decrement | `inFlightSaves[userId] -= 1` (always) | Releases the counter slot this operation owns; **must precede Step 2**: if Step 2 returned `false` before Step 1, `inFlightSaves` would stay > 0 permanently → Phase-2 observer loops forever → BindToClose deadlocks |
| 2 — Identity check | `sessionTokens[userId] == token` | Prevents stale T_A completion from modifying T_B state; requires `sessionTokens` preserved through step 2 of disconnectPlayer |
| 3 — Session-loss | Invalidate only if state == "active" | No kick when player already disconnecting/abandoned |
| 4 — Drain-timeout cleanup | Clear `sessionTokens`, `inFlightSaves`, `playerState` when abandoned + counter == 0 | Only safe after Steps 1–3; `sessionTokens` cleared here (not earlier); `inFlightSaves` set to nil here for consistency with step-7 cleanup |
| 5 — Normal return | `return saveSucceeded` | Regular autosave completion for active session |

**Token-mismatch non-nil result:** If `UpdateAsync` returns the existing DataStore value (not nil) when our callback returned nil, `result._session.token` will be another server's token. The `ok and` branch (above) catches this: `result ~= nil but token ~= our token` → `confirmedSessionLoss = true`. This is the second path that correctly detects session loss without relying on `result == nil` alone.

### 6.4 Execution timeline — save snapshot + callback retry with ownership change

```
T0  Server A: savePlayer starts
    token    = sessionTokens[X] = T_A   (captured — immutable string)
    snapshot = deepCopy(loadedData[X])  (captured — immutable table)
    inFlightSaves[X] = 1
    UpdateAsync yields

T1  Callback call 1: current._session.token == T_A → match
    → newRecord = deepCopy(snapshot); newRecord._session = current._session
    → write {snapshot_data, _session:{T_A, released:false}}

T2  Write reaches DataStore; ack is lost (network partition)

T3  Server B: loadPlayer — TTL not yet expired; sees T_A as live → Server B's callback returns nil
    → Server B kicks its player ✅ (Server A's lock is live)

    (Assume T_A TTL eventually expires; Server B retries and acquires with T_B)

T4  Roblox retries Server A's callback:
    current = {_session:{token:T_B}} (Server B's session)

T5  Callback call 2: current._session.token == T_B ≠ T_A → return nil

T6  UpdateAsync returns (Behaviour A) nil OR (Behaviour B) current record {_session:{T_B}}
    Both handled:
    Behaviour A: ok=true, result=nil                           → confirmedSessionLoss=true
    Behaviour B: ok=true, result._session.token==T_B ≠ T_A    → confirmedSessionLoss=true

T7  inFlightSaves[X] decremented to 0 (Step 1)
T8  Step 2: sessionTokens[X]==T_A==capturedToken → identity check passes (session still current).
    Step 3: confirmedSessionLoss=true; playerState[X]=="active" → genuine ownership loss.
    playerState[X]="invalidated"; invalidated[X]=true; player kicked; return false. ✅
T9  CORRECT: Server A's snapshot is not written; Server B's session is not disturbed.

ALSO CORRECT: snapshot was captured before the UpdateAsync call.
Even if loadedData[X] is cleared at T1 by a concurrent releaseSession, the
callback at T1 and T4 uses only `snapshot` and `token` — both are unaffected. ✅
```

### 6.5 `disconnectSave` — Disconnect-path save (internal)

`disconnectSave` is an **internal function** called only from `disconnectPlayer` (§10.1), after in-flight autosaves have fully drained. It is the only save operation permitted in `"disconnecting"` state. Regular autosaves (`savePlayer`) reject `"disconnecting"` immediately via the state guard in §6.1.

**Interface:**

```
function disconnectSave(userId, player, token, snapshot):
    -- Preconditions (all verified by disconnectPlayer before calling):
    --   playerState[userId] == "disconnecting"
    --   inFlightSaves[userId] == 0
    --   token is the value captured from sessionTokens[userId] in disconnectPlayer step 2
    --     (sessionTokens[userId] is NOT cleared in step 2 — it is preserved for §6.3 Step-2
    --      identity check; it is cleared in step 7 or by §6.3 Step 4)
    --   snapshot is deepCopy(loadedData[userId]) taken after all autosaves drained
```

**Guards:**

```
if playerState[userId] ~= "disconnecting": return false
if token == nil: return false
if snapshot == nil: return false
```

**Callback (same structure as §6.2; uses captured token and snapshot):**

```
callback(current):
    if current == nil or current._session == nil:
        return nil
    if current._session.token ~= token:
        return nil                       -- session superseded during disconnect
    newRecord = deepCopy(snapshot)
    newRecord._session = current._session
    return newRecord
```

**Verification, retry, and counter (same structure as §6.3):**

```
inFlightSaves[userId] = 1

local confirmedSessionLoss = false
local saveSucceeded = false

for attempt = 1 to SAVE_RETRIES:
    local ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)
    
    if ok and result ~= nil and result._session ~= nil and result._session.token == token:
        saveSucceeded = true; break
    
    if ok:
        -- result == nil (callback returned nil) OR result._session.token ~= token.
        -- Both indicate ownership loss. Do not retry.
        confirmedSessionLoss = true; break
    
    if not ok:
        warn("disconnectSave attempt " .. attempt .. "/" .. SAVE_RETRIES)
        if attempt < SAVE_RETRIES: task.wait(SAVE_BACKOFF * attempt)

inFlightSaves[userId] = 0   -- decremented unconditionally

if confirmedSessionLoss:
    playerState[userId] = "abandoned"   -- session stolen; no release needed; TTL handles it
    invalidated[userId] = true
    warn("disconnectSave: session ownership lost for userId=" .. userId)
    return false

if not saveSucceeded:
    warn("disconnectSave: all retries exhausted for userId=" .. userId)
    -- playerState remains "disconnecting"; disconnectPlayer transitions it to "abandoned"
    return false

return true
```

**Why `disconnectSave` and not `savePlayer`:**

`savePlayer` reads `sessionTokens[userId]` to get its token and checks for state `"active"`. `disconnectPlayer` transitions state to `"disconnecting"` in step 1 and captures `sessionTokens[userId]` as a local variable without clearing it (D-20 fix — `sessionTokens` is preserved for the §6.3 identity check in the drain-timeout path). `savePlayer` is therefore blocked by the state guard (`"disconnecting" ≠ "active"`) alone. `disconnectSave` accepts an explicit `token` and `snapshot` passed from `disconnectPlayer` and checks for `"disconnecting"` state directly, so it is not affected by the state change and does not need to read `sessionTokens[userId]`.

**Session loss during disconnect save:** If `disconnectSave` detects ownership loss, state transitions to `"abandoned"` and `invalidated[userId]` is set. `disconnectPlayer` checks the return value and skips `releaseSession` — there is nothing to release because another server holds the session. The stolen session's TTL countdown is not affected.

---

## 7. `refreshSession`

### 7.1 Callback

The callback updates `_session.since` to prevent TTL expiry. It verifies ownership from the returned record — no closure mutation.

**The callback must capture `token` as a read-only closure variable and compare against that captured value.** It must never read `sessionTokens[userId]` directly inside the callback body — that table is shared mutable state that can change between callback retries (cleared by step-7 cleanup after a normal disconnect, or changed to a new session's token if the player rejoins as T_B). The captured local `token` is the only stable reference across all retry scenarios. The token is captured once in the outer function (§7.2) before the `UpdateAsync` call.

```
-- token is captured in §7.2 as: local token = sessionTokens[userId]
-- The callback closes over this immutable captured value.

callback(current):
    if current == nil or current._session == nil: return nil
    if current._session.token ~= token: return nil  -- token is a captured read-only local
    newRecord = deepCopy(current)
    newRecord._session.since = os.time()
    return newRecord
```

### 7.2 Verification after UpdateAsync

The token is captured once before the `UpdateAsync` call. The callback and all result verification use this captured local — `sessionTokens[userId]` is never read again after capture. This is the same pattern as §6.1–6.3 (savePlayer) and prevents incorrect ownership-loss detection if `sessionTokens[userId]` changes while the callback is in-flight or being retried — for example, cleared by step-7 cleanup after a normal disconnect, or updated to T_B's token when the player rejoins.

**Dual identity check:** Before applying any refresh result to per-player state, two conditions must both hold:
1. `playerState[userId] == "active"` — the player has not entered a disconnect or post-disconnect state
2. `sessionTokens[userId] == token` (the captured value) — the captured token still identifies the currently active session; a different token means a new session T_B is active

If either check fails, this refresh operation belongs to a stale or disconnecting session. It must not modify `playerState`, `invalidated`, `lastRefresh`, or kick the player.

**Why the second check is necessary:** After cleanup clears `playerState[userId]` to nil (step 7 on normal/save-failed paths; `§6.3 Step 4` on the drain-timeout path), the player can rejoin on the same server and `loadPlayer` can run again (§5.1 accepts nil state). The new session T_B sets `playerState[userId] = "active"` and `sessionTokens[userId] = T_B`. If the old T_A refresh completes now, `playerState == "active"` passes — but `sessionTokens[userId] == T_B ≠ T_A` (the captured token). The second check catches this case. Without it, the stale T_A refresh would invalidate and kick the new T_B session.

```
local token = sessionTokens[userId]  -- capture before UpdateAsync; stable reference
                                     -- callback uses this value, not sessionTokens[userId]
ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)

if ok:
    if result ~= nil and result._session ~= nil and result._session.token == token:
        -- Confirmed refresh. Apply only if this result belongs to the current active session.
        if playerState[userId] ~= "active" or sessionTokens[userId] ~= token:
            -- State has transitioned (disconnect in progress or complete) or a new session
            -- has taken over. Ignore this stale success silently.
            return false
        lastRefresh[userId] = os.time()
        return true
    else:
        -- result == nil (callback returned nil) OR
        -- result._session.token ~= token (non-nil result, wrong token)
        -- The callback correctly detected a token mismatch in DataStore.
        
        -- Dual identity check: both conditions must hold for this to be a genuine
        -- ownership-loss event that should invalidate the current session.
        if playerState[userId] ~= "active":
            -- Disconnect or post-disconnect state: "disconnecting", "released", "abandoned".
            -- Do NOT set "invalidated": the disconnect lifecycle handles cleanup.
            -- Do NOT kick: the player is already leaving or has already left.
            return false
        
        if sessionTokens[userId] ~= token:
            -- A new session (T_B) is now active on this server for the same userId.
            -- This refresh result belongs to the old session (T_A). Ignoring it silently
            -- prevents the stale T_A result from invalidating or kicking the T_B player.
            return false
        
        -- Both checks passed: genuine ownership loss in "active" state for this session.
        playerState[userId] = "invalidated"
        invalidated[userId] = true
        warn("Session ownership lost during refresh for userId=" .. userId)
        local player = Players:GetPlayerByUserId(tonumber(userId))
        if player: player:Kick("Your session was claimed by another server.")
        return false

if not ok:
    warn("refresh DataStore error for userId=" .. userId)
    return false                               -- non-fatal single failure; see §7.3
```

**Distinction between callback and result-handler ownership verification:**

The callback's ownership check (captured token vs `current._session.token`) verifies **DataStore ownership**: "does the DataStore record still belong to this session's token?" It runs inside UpdateAsync, with no access to current in-memory state.

The result handler's dual identity check (state guard + token identity) verifies **session currency**: "is this session's result still relevant to the player currently loaded on this server?" It runs after UpdateAsync returns, with access to current in-memory state. These are two independent correctness checks that serve different failure modes.

### 7.3 Persistent refresh failure handling

The refresh loop tracks `lastRefresh[userId]`. On each DataStore error, the same dual identity check applies: both `playerState[userId] == "active"` AND `sessionTokens[userId] == token` (the captured value) must hold before treating TTL expiry as a reason to invalidate the current session.

```
if os.time() - (lastRefresh[userId] or 0) > LOCK_TTL:
    -- Lock has certainly expired; treat as stolen.
    
    -- Dual identity check (same as §7.2):
    if playerState[userId] ~= "active":
        return false   -- disconnect in progress or already complete; do not interfere
    
    if sessionTokens[userId] ~= token:
        return false   -- a new session T_B is now active; stale T_A failure must not kick T_B
    
    -- Both checks passed: genuine TTL expiry for the currently active session.
    playerState[userId] = "invalidated"
    invalidated[userId] = true
    kick(...)
```

A single transient failure does not trigger a kick if `os.time() - lastRefresh < LOCK_TTL` (the lock has not yet expired). The dual identity check applies equally to the TTL-expiry path.

### 7.4 Refresh loop

```
task.spawn(function()
    while true do
        task.wait(LOCK_REFRESH)
        for userId in pairs(activeLocks) do
            task.spawn(function()
                refreshSession(userId)
            end)
        end
    end
end)
```

### 7.5 In-flight refresh at disconnect — lifecycle interaction and TTL analysis

When `disconnectPlayer` clears `activeLocks[userId]` (§10.1 step 2), the refresh loop stops iterating this player on its next cycle. However, a `refreshSession` task that is **already running** (yielded inside its `UpdateAsync`) is not interrupted. It captured its `token` from `sessionTokens[userId]` before the disconnect and continues to completion with that captured value.

**Will the in-flight refresh falsely detect ownership loss?**

No — with the fixed callback (§7.1). The callback uses the captured `token` (not live `sessionTokens[userId]`). With the D-20 fix, `disconnectPlayer` does not clear `sessionTokens[userId]` in step 2 — `sessionTokens` is preserved for the §6.3 identity check in the drain-timeout path. Even so, the callback's correctness does not depend on `sessionTokens`: it closes over the captured local `token` from §7.2, which cannot be changed by any external operation. If the session has not been stolen, the comparison succeeds and the refresh completes normally. Only a genuine token mismatch in DataStore (another server holds the session) causes the callback to return nil.

**Will the in-flight refresh overwrite `"disconnecting"` state, or a later "active" session?**

No — the dual identity check in §7.2 covers both cases:

- *During disconnect*: `playerState == "disconnecting"` → first check fails → return false. `disconnectSave` unblocked.
- *After disconnect cleanup and player rejoin*: cleanup clears `playerState` to nil and `sessionTokens` to nil. New `loadPlayer` runs for T_B: state → "active", `sessionTokens[userId] = T_B`. Old T_A refresh completes: `playerState == "active"` passes first check, but `sessionTokens[userId] == T_B ≠ T_A` (captured by T_A) → second check fails → return false. T_B session is unaffected.

**Can an in-flight refresh extend the TTL?**

Yes. If the refresh completes successfully, it writes `_session.since = os.time()` to DataStore. In the **normal path**, `disconnectSave` and `releaseSession` both complete, writing `released=true`. Another server can acquire immediately from `released=true`, regardless of `_session.since`. The in-flight refresh has no effect.

In the **abandoned path** (drain timeout), `releaseSession` is never called. Another server can acquire only after `(now - sess.since) >= LOCK_TTL`. The TTL fallback becomes available **LOCK_TTL seconds after the last successful `_session.since` write in DataStore**, which may be later than when `activeLocks` was cleared if an in-flight refresh completed after disconnect began. This residual risk is documented in §15 Risk 8.

---

## 8. Session Release — Internal Helper

`releaseSession` is an **internal helper** called only from `disconnectPlayer` (§10), and only after `disconnectPlayer` has confirmed `inFlightSaves[userId] == 0`. It never waits for saves internally; that is `disconnectPlayer`'s responsibility.

### 8.1 Precondition

`releaseSession` is called only when:
- `playerState[userId] == "disconnecting"` (set by `disconnectPlayer`)
- `inFlightSaves[userId] == 0` (confirmed by drain AND by `disconnectSave` returning `true` — `disconnectSave` is synchronous and decrements the counter before returning)
- `sessionTokens[userId]` still holds T_A's token at this point (not cleared in step 2 — see D-20 fix); it will be cleared in step 7 cleanup
- `disconnectSave(userId, player, token, snapshot)` returned `true` (save committed)

### 8.2 Token capture and callback

```
function releaseSession(userId):
    local token = sessionTokens_captured  -- passed in by disconnectPlayer (see §10)
    -- token is the value that was in sessionTokens[userId] before disconnectPlayer cleared it.
    
    local released = false
    for attempt = 1 to RELEASE_RETRIES (3):
        ok, result = pcall(PlayerStore.UpdateAsync, userId, function(current)
            if current == nil or current._session == nil: return nil
            if current._session.token ~= token: return nil  -- not our session
            newRecord = deepCopy(current)
            newRecord._session.released = true
            return newRecord
        end)
        
        if ok and result ~= nil and result._session ~= nil
                and result._session.token == token and result._session.released == true:
            released = true; break                           -- confirmed release
        
        if ok and (result == nil
                or (result._session ~= nil and result._session.token ~= token)):
            -- Another server holds this session. It has already been superseded.
            -- The session is effectively released from our perspective.
            released = true; break
        
        if not ok:
            warn("release attempt " .. attempt .. "/" .. RELEASE_RETRIES)
            if attempt < RELEASE_RETRIES: task.wait(SAVE_BACKOFF * attempt)
    
    if released:
        playerState[userId] = "released"
    else:
        -- All retries failed (pure DataStore errors). Session will expire by TTL.
        playerState[userId] = "abandoned"
        warn("Release failed for userId=" .. userId .. ". Session expires in ~" .. LOCK_TTL .. "s.")
    
    return released
```

**TTL safety net:** Whether `released` or `abandoned`, `activeLocks[userId]` was cleared by `disconnectPlayer` before calling this function. No refresh will fire for this player. The session will not be re-acquired by another server until either (a) `released=true` is in DataStore, or (b) LOCK_TTL seconds elapse from the last confirmed refresh.

### 8.3 Execution timeline — single in-flight save at disconnect

This corresponds to the normal-path timeline from `disconnectPlayer` (§10.4, Timeline A).

```
T0  disconnectPlayer starts for X. State="active"→"disconnecting".
    activeLocks[X]=nil; captured token=T_A. (sessionTokens[X]=T_A preserved — D-20 fix; not cleared until step 7.)
T1  Drain wait: inFlightSaves[X]==0 → no wait (no autosave in flight). Pass.
T2  snapshot=deepCopy(loadedData[X]) taken.
    disconnectSave(X, player, T_A, snapshot): inFlightSaves[X]=1; UpdateAsync yields.
T3  disconnectSave UpdateAsync completes:
    result._session.token==T_A → confirmed ✅; inFlightSaves[X]=0; return true.
T4  releaseSession(X, T_A) called.
    Callback: current._session.token==T_A → released=true; state→"released" ✅
Final DataStore: {snapshot, _session:{T_A, released:true}} ✅
```

---

## 9. `getData`, `addCash`, `spendCash` — Session Validity Guard (Issue 3 fix)

The existing `loadFailed` table only blocks saves. It does not block `getData`, so `addCash` and `spendCash` can modify an in-memory profile after session loss. The fix introduces `invalidated[userId]` (which replaces `loadFailed`).

### 9.1 `invalidated[userId]`

Set to `true` when:
- `loadPlayer` fails (all retries exhausted)
- Confirmed session loss in `savePlayer` callback (§6.3)
- Confirmed session loss in `refreshSession` callback (§7.2)
- Persistent refresh failure (§7.3, elapsed > LOCK_TTL)

### 9.2 `getData` updated guard

```
function PlayerDataManager.getData(player):
    local userId = tostring(player.UserId)
    if invalidated[userId] then return nil end
    if playerState[userId] ~= "active" then return nil end
    return loadedData[userId]
```

`addCash` and `spendCash` both call `getData` → automatically return nil or false when `invalidated` or state is not `"active"`. No additional changes required in those functions. During `"disconnecting"` state, `getData` returns nil — game logic is blocked from modifying the player's data while the disconnect lifecycle runs. `disconnectSave` reads `loadedData` directly (via the `snapshot` parameter from `disconnectPlayer`), not through `getData`.

### 9.3 Execution timeline — mutation after ownership loss (Issue 3 fix)

```
T0  Player on Server A: state="active", token=T_A. Income tick fires every second.
T1  Server A refresh: 3 consecutive DataStore errors; os.time()-lastRefresh[X] > LOCK_TTL
    → invalidated[X] = true; playerState[X] = "invalidated"
    → Player kicked (kick may take a few scheduler yields to reach the client)
T2  Income tick fires before kick is delivered:
    addCash(X, 100) → getData(X) → invalidated[X]==true → return nil → addCash: data==nil → no-op ✅
T3  Another income tick fires:
    getData(X) → nil → no-op ✅
T4  Player is kicked (delivery of kick from T1 reaches client)
T5  Income ticks stop (player no longer in game)
Data integrity: no modifications to stale in-memory profile after T1 ✅
```

---

## 10. Disconnect and Shutdown

All disconnect logic is centralised in `disconnectPlayer`. Both `PlayerRemoving` and `BindToClose` call it. A `shuttingDown[userId]` flag ensures only one caller owns the lifecycle. The second (observing) caller does **not** return immediately — it waits for the owner to complete all outstanding operations before returning (see §10.3). This ensures `BindToClose`'s completion counter reflects actual operation completion, not just lifecycle ownership transfer.

### 10.1 `disconnectPlayer` — unified shutdown lifecycle

The lifecycle enforces a strict sequential order: drain autosaves → disconnect save → release. Each step must complete before the next begins. If any deadline is exceeded, the session is not released in DataStore; it expires by TTL instead, and state transitions to "abandoned".

```
-- shuttingDown[userId] = nil | true  (guards single ownership)
-- DRAIN_DEADLINE = 5 s  (time to wait for in-flight autosaves)

function disconnectPlayer(userId, player):
    -- 1. Single-owner guard (two-phase wait for observing caller)
    if shuttingDown[userId]:
        -- Phase 1: wait for the lifecycle owner to exit (shuttingDown cleared in every cleanup path).
        while shuttingDown[userId] do
            task.wait(0.05)
        end
        -- Phase 2: wait for any saves left outstanding by the drain-timeout path.
        -- In the normal path, inFlightSaves was cleared to nil in step 7 cleanup → (nil or 0) == 0.
        -- In the drain-timeout path, the owner cleared shuttingDown but left inFlightSaves > 0.
        -- We wait here so disconnectCount is not decremented while a save is still in flight.
        while (inFlightSaves[userId] or 0) > 0 do
            task.wait(0.05)
        end
        return   -- all operations complete; safe to decrement BindToClose counter
    
    -- D-21: Terminal state cleanup for "failed" and "invalidated" states.
    -- These states arise from loadPlayer failure or in-game session loss.
    -- The disconnect lifecycle (drain→save→release) was never entered, so there is no
    -- lifecycle owner, no shuttingDown flag, and no disconnect snapshot to take.
    -- PlayerRemoving calls disconnectPlayer after the kick delivers; clean up here.

    if playerState[userId] == "failed" then
        -- Session was never activated (§5.6 never ran); no async operations outstanding.
        -- Safe to clear all state immediately.
        playerState[userId] = nil
        invalidated[userId] = nil
        return
    end

    if playerState[userId] == "invalidated" then
        -- Autosaves may still be in flight (they captured token before invalidation).
        -- They will all complete with confirmedSessionLoss (session is stolen), so there
        -- is no data to write. BindToClose does not need to wait for them.
        --
        -- Clear data-serving tables immediately (safe regardless of inFlightSaves):
        loadedData[userId]  = nil
        invalidated[userId] = nil
        activeLocks[userId] = nil
        lastRefresh[userId] = nil
        -- shuttingDown[userId] is nil here (lifecycle was never owned for this player).

        if (inFlightSaves[userId] or 0) == 0 then
            -- No in-flight saves outstanding. Full cleanup now.
            sessionTokens[userId] = nil
            inFlightSaves[userId] = nil
            playerState[userId]   = nil
        else
            -- In-flight saves remain. Transition to "abandoned" so §6.3 Step 4 performs
            -- deferred cleanup (clears sessionTokens, inFlightSaves, playerState when
            -- the last save completes and inFlightSaves reaches 0).
            -- The cooperative scheduler guarantees this assignment is atomic at coroutine
            -- boundaries, so no save completion can observe an intermediate state.
            playerState[userId] = "abandoned"
        end
        return
    end

    if playerState[userId] ~= "active": return       -- not in a state we can disconnect
    shuttingDown[userId] = true
    playerState[userId] = "disconnecting"
    
    -- 2. Stop refresh; capture token for disconnect save and release (D-20 fix)
    activeLocks[userId] = nil                        -- refresh loop stops iterating this player
    local token = sessionTokens[userId]              -- capture for disconnectSave and releaseSession
    -- sessionTokens[userId] is NOT cleared here. Autosaves are already blocked by the state
    -- guard ("disconnecting"). Preserving sessionTokens allows §6.3's Step-2 dual identity check
    -- to remain valid if drain times out and the autosave completes after disconnectPlayer exits.
    -- sessionTokens is cleared in step 7 (normal / save-failed) or by §6.3 (drain-timeout).
    
    -- 3. Drain in-flight autosaves
    --    Any autosave that captured its token before step 2 may still be in flight.
    --    Wait for it to complete (decrement inFlightSaves) before proceeding.
    local drainDeadline = os.clock() + DRAIN_DEADLINE
    while (inFlightSaves[userId] or 0) > 0 and os.clock() < drainDeadline:
        task.wait(0.05)
    
    if (inFlightSaves[userId] or 0) > 0:
        -- Autosave did not complete within deadline. Cannot guarantee snapshot ordering.
        -- Do NOT proceed with disconnect save or release.
        -- Session expires by TTL (activeLocks cleared → no refreshes → TTL countdown from
        -- last _session.since write in DataStore, which may be later than this point
        -- if an in-flight refresh completed after disconnect began — see §7.5).
        playerState[userId] = "abandoned"
        warn("disconnectPlayer: autosave drain timeout for userId=" .. userId
             .. ". Session expires in ~" .. LOCK_TTL .. "s from last DataStore refresh write.")
        -- inFlightSaves is NOT cleared: the autosave owns its counter slot.
        -- It will decrement inFlightSaves[userId] itself when its UpdateAsync completes.
        loadedData[userId]    = nil
        invalidated[userId]   = nil
        lastRefresh[userId]   = nil
        -- sessionTokens[userId] is left intact intentionally (D-20 fix).
        -- §6.3 Step 2 requires sessionTokens to be non-nil to verify that this autosave's
        -- completion belongs to the T_A session (not a newer T_B). §6.3 Step 4 clears it.
        --
        -- playerState[userId] is left as "abandoned" (non-nil) intentionally.
        -- §5.1 rejects non-nil state → no rejoin until autosave completes and §6.3 clears it.
        -- After the decrement, §6.3 Step 4 clears playerState[userId] = nil when
        -- inFlightSaves[userId] == 0 and state is "abandoned".
        
        shuttingDown[userId]  = nil
        -- Clearing shuttingDown signals "lifecycle owner has exited" to any observing caller.
        -- An observer's Phase-1 wait exits here. It then enters Phase-2: waits for
        -- inFlightSaves[userId] == 0. The BindToClose disconnectCount is NOT decremented
        -- until Phase-2 also exits. This is the correct completion protocol.
        return
    
    -- 4. Take final snapshot (all autosaves committed; this is the most recent data)
    --    Snapshot is taken here, AFTER drain, so it reflects all mutations committed
    --    by any autosave that ran before disconnectPlayer started.
    local snapshot = deepCopy(loadedData[userId])
    
    -- 5. Disconnect save (via disconnectSave — the only save permitted in "disconnecting" state)
    --    disconnectSave is synchronous: when it returns, inFlightSaves[userId] is 0.
    --    It uses the explicitly captured token and snapshot — not sessionTokens
    --    or loadedData (safe to clear after this call).
    local saveOk = disconnectSave(userId, player, token, snapshot)
    
    if not saveOk:
        -- Either confirmed session loss (disconnectSave set state→"abandoned")
        -- or all retries exhausted (state remains "disconnecting"; set to "abandoned" here).
        if playerState[userId] ~= "abandoned":
            playerState[userId] = "abandoned"
        warn("disconnectPlayer: save failed for userId=" .. userId
             .. ". Session expires by TTL.")
        loadedData[userId]    = nil
        invalidated[userId]   = nil
        lastRefresh[userId]   = nil
        inFlightSaves[userId] = nil   -- disconnectSave already decremented to 0
        sessionTokens[userId] = nil
        shuttingDown[userId]  = nil
        playerState[userId]   = nil   -- clear terminal state; enables rejoin on same server
        return
    
    -- 6. Release session (inFlightSaves[userId] == 0 confirmed by disconnectSave returning true)
    releaseSession(userId, token)    -- internal helper; see §8
    
    -- 7. Cleanup (all async operations complete)
    loadedData[userId]    = nil
    invalidated[userId]   = nil
    lastRefresh[userId]   = nil
    inFlightSaves[userId] = nil
    sessionTokens[userId] = nil      -- cleared here; was preserved through step 2 for §6.3 identity check
    shuttingDown[userId]  = nil
    playerState[userId]   = nil   -- clear "released" or "abandoned"; enables rejoin on same server
    -- Clearing playerState to nil is safe here: all async operations (drain, disconnectSave,
    -- releaseSession) have completed. No in-flight callbacks remain. A new loadPlayer
    -- can now start for this userId if the player rejoins.
```

**Why state tables are only cleared after all async operations complete:**

- Steps 3 and 5 each confirm `inFlightSaves[userId] == 0` before proceeding. By step 7, no save UpdateAsync calls are outstanding for this lifecycle.
- In the drain-timeout path (step 3 failure), `loadedData` is cleared but `inFlightSaves` is NOT — the in-flight autosave still holds a reference and will decrement it when its `UpdateAsync` completes. Clearing `inFlightSaves` early would cause a nil arithmetic error.
- In the save-failed path (step 5 failure), `disconnectSave` has already decremented `inFlightSaves` to 0 before returning. `inFlightSaves[userId]` is cleared here as a cleanup step (it is already 0 or nil).

**Async operation lifecycle — what is tracked and what may safely outlive cleanup (D-18):**

Two categories of async DataStore operations can be in-flight during or after `disconnectPlayer`:

| Operation | Tracked by | Must drain before BindToClose returns? | Safety mechanism |
|---|---|---|---|
| Autosave (`savePlayer`) UpdateAsync | `inFlightSaves[userId]` counter | Yes — BindToClose Phase-2 wait | Callback uses captured immutable token + snapshot |
| Disconnect save (`disconnectSave`) UpdateAsync | `inFlightSaves[userId]` = 1 | Yes — but only run in normal path where drain passed | Same pattern |
| `refreshSession` UpdateAsync | Not tracked | No — may safely outlive cleanup | Dual identity check in §7.2/§7.3 blocks stale results |

`refreshSession` tasks are deliberately excluded from `inFlightSaves`. When `disconnectPlayer` clears `activeLocks[userId]` in step 2, the refresh loop stops scheduling new refreshes for this player. Any refresh task already running (past its yield point inside `UpdateAsync`) continues to completion independently. The dual identity check (`playerState == "active" AND sessionTokens == capturedToken`) ensures its result cannot modify state belonging to a different session. BindToClose does not need to wait for refresh tasks to complete.

**Why not track refresh tasks:** Refresh tasks are fire-and-forget (spawned per-player on a 20s cycle). Adding a counter would require coordination across the refresh loop and `disconnectPlayer`, introducing more state to clear. The dual identity check provides the same correctness guarantee at lower complexity. The tradeoff is accepted: a refresh task may still be in flight when the server shuts down, but it cannot corrupt any per-player state.

### 10.2 `PlayerRemoving`

```
Players.PlayerRemoving:Connect(function(player)
    local userId = tostring(player.UserId)
    disconnectPlayer(userId, player)
end)
```

### 10.3 `BindToClose`

**Completion protocol:**

`disconnectPlayer`'s single-owner guard uses a **two-phase wait** (see §10.1 step 1 pseudocode):

- **Phase 1** — wait for `shuttingDown[userId]` to clear. This signals "the lifecycle owner has exited its logic." In the normal path, this means drain + save + release all completed before the owner returned. In the drain-timeout path, the owner has exited but an autosave may still be in flight.
- **Phase 2** — wait for `(inFlightSaves[userId] or 0) == 0`. This ensures outstanding autosaves from the drain-timeout path have fully completed. In the normal path, `inFlightSaves` was cleared to nil in step 7 cleanup → `(nil or 0) == 0` is immediately true.

Only after both phases does the observer return and `disconnectCount -= 1` fire.

**Operations covered by this protocol:**

- Autosaves (`savePlayer` UpdateAsync): tracked by `inFlightSaves`; Phase-2 wait drains these ✓
- Disconnect save (`disconnectSave` UpdateAsync): synchronous within lifecycle; completed before owner clears `shuttingDown` ✓
- Release UpdateAsync: same — completed before owner clears `shuttingDown` ✓
- Refresh tasks (`refreshSession` UpdateAsync): **not tracked**; may still be in flight when BindToClose returns. Protected by dual identity check in §7.2/§7.3; they cannot corrupt any session's state. See D-18 discussion above.

**25-second deadline:**

Official Roblox documentation (`DataModel:BindToClose`) states: *"The experience server waits 30 seconds for all bound functions to stop."* The 25-second internal deadline leaves a 5-second buffer for BindToClose's own overhead, logging, and cleanup after the outer loop exits, before Roblox's hard 30-second shutdown fires.

The two-phase wait runs inside the observer's `task.spawn`'d coroutine. The BindToClose outer loop (`while disconnectCount > 0 and os.clock() < deadline`) runs concurrently. If Phase-2 takes longer than 25 s from BindToClose entry (e.g., autosave is stalled and never completes), the outer deadline fires: BindToClose logs a warning and returns, allowing the server to shut down. The observer's spawned tasks may still be running, but Roblox kills all scripts on server shutdown regardless.

**Remaining limitation:** The 5-second buffer between the 25s internal deadline and the 30s Roblox hard shutdown is consumed by final logging, any cleanup code that runs after the outer loop exits, and scheduling latency. If the 25s internal deadline is tightened without also adjusting the buffer, tasks may be killed before logging completes. The 25s/5s split should be re-evaluated if `DRAIN_DEADLINE` or `SAVE_RETRIES × SAVE_BACKOFF` are increased.

**Degraded outcome when deadline fires:** outstanding saves or disconnect operations are abandoned. Data written since the last committed save (autosave or disconnect save) is lost for affected players. This is the documented worst-case degraded path.

```
game:BindToClose(function()
    local disconnectCount = 0
    for _, player in ipairs(Players:GetPlayers()) do
        disconnectCount += 1
        local userId = tostring(player.UserId)
        task.spawn(function()
            disconnectPlayer(userId, player)
            -- disconnectPlayer returned after Phase-1 (shuttingDown cleared) AND
            -- Phase-2 (inFlightSaves cleared). All tracked operations complete.
            disconnectCount -= 1
        end)
    end
    local deadline = os.clock() + 25
    while disconnectCount > 0 and os.clock() < deadline do
        task.wait(0.1)
    end
    if disconnectCount > 0 then
        warn("[DataManager] BindToClose: 25s deadline reached with " .. disconnectCount
             .. " player(s) with outstanding saves or disconnect in progress.")
    end
end)
```

### 10.4 Execution timelines

**Timeline A: PlayerRemoving fires, no autosave in flight**

```
T0  PlayerRemoving calls disconnectPlayer(X).
    shuttingDown[X]=true; state→"disconnecting"; activeLocks[X]=nil; token=T_A.
    (sessionTokens[X] NOT cleared here — preserved for §6.3 identity check.)
T1  Drain: inFlightSaves[X]==0 → pass immediately.
T2  snapshot=deepCopy(loadedData[X]) taken.
    disconnectSave(X, player, T_A, snapshot): inFlightSaves[X]=1; UpdateAsync yields.
T3  disconnectSave UpdateAsync completes:
    result._session.token==T_A → ✅; inFlightSaves[X]=0; return true.
T4  releaseSession(X, T_A): token match → released=true → state→"released" ✅
T5  Step-7 Cleanup: loadedData[X]=nil; inFlightSaves[X]=nil; sessionTokens[X]=nil; shuttingDown[X]=nil.
```

**Timeline B: Autosave in flight when PlayerRemoving fires**

```
T0  Autosave: savePlayer(X); token=T_A captured; snapshot_T0 captured; inFlightSaves[X]=1; UpdateAsync yields.
T1  PlayerRemoving: disconnectPlayer(X).
    shuttingDown[X]=true; state→"disconnecting"; activeLocks[X]=nil; token=T_A.
    (sessionTokens[X] NOT cleared.)
T2  Drain: inFlightSaves[X]==1 > 0 → wait(0.05) loop.
T3  Autosave UpdateAsync completes; inFlightSaves[X]=0 → drain passes.
    (DataStore now has the autosave snapshot_T0.)
T4  snapshot_T1=deepCopy(loadedData[X]) taken (all mutations up to T4).
    disconnectSave(X, player, T_A, snapshot_T1): inFlightSaves[X]=1; UpdateAsync yields.
T5  disconnectSave UpdateAsync completes:
    result._session.token==T_A → ✅; inFlightSaves[X]=0.
    DataStore: {snapshot_T1, _session:{T_A}} (snapshot_T1 ≥ snapshot_T0 by time ordering).
T6  releaseSession(X, T_A): released=true; state→"released" ✅.
T7  Step-7 Cleanup: loadedData[X]=nil; inFlightSaves[X]=nil; sessionTokens[X]=nil; shuttingDown[X]=nil.
```

No two saves are in flight simultaneously. The disconnect save always starts after any prior autosave completes. snapshot_T1 captures all data written between T0 (autosave capture) and T4 (disconnect capture). The final DataStore state is snapshot_T1, which is the most recent snapshot. ✅

**Timeline C: PlayerRemoving fires first; BindToClose observes; normal completion (Revision 9)**

```
T0  PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle starts.
T1  BindToClose iterates Players. Player X is in the list.
    task.spawn → disconnectPlayer(X) → shuttingDown[X]==true →
    Phase 1: while shuttingDown[X] do task.wait(0.05) end → loops.
T2  PlayerRemoving lifecycle completes normally (drain+save+release).
    Step 7 cleanup: inFlightSaves[X]=nil; sessionTokens[X]=nil; shuttingDown[X]=nil; playerState[X]=nil.
T3  Phase 1 exits (shuttingDown nil). Phase 2: (inFlightSaves[X] or 0) = (nil or 0) = 0 → pass immediately.
T4  Observer returns → disconnectCount -= 1 ✅
Expected: Counter decremented only after all operations complete. Normal path: no Phase-2 wait. PASS
```

**Timeline D: BindToClose fires first; PlayerRemoving observes; normal completion (Revision 9)**

```
T0  BindToClose: task.spawn → disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle starts.
T1  PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]==true →
    Phase 1: while shuttingDown[X] do task.wait(0.05) end → loops.
T2  BindToClose lifecycle completes normally. Cleanup: inFlightSaves[X]=nil; sessionTokens[X]=nil; shuttingDown[X]=nil.
T3  Phase 1 exits. Phase 2: (nil or 0) = 0 → pass immediately.
T4  PlayerRemoving observer returns. ✅
Expected: Exactly one save, one release. PlayerRemoving observer does no saves. PASS
```

**Timeline E: Autosave drain timeout — TTL path; autosave completes after disconnect exits**

```
T0  Autosave: savePlayer(X); capturedToken=T_A; inFlightSaves[X]=1; UpdateAsync stalled.
T1  PlayerRemoving: disconnectPlayer(X). state→"disconnecting"; activeLocks[X]=nil.
    (sessionTokens[X] NOT cleared — preserved for §6.3 Step-2 identity check.)
T2  Drain: inFlightSaves[X]==1 > 0; wait loop.
T3  After DRAIN_DEADLINE (5s): inFlightSaves[X] still 1 → drain timeout.
    state→"abandoned"; loadedData[X]=nil; shuttingDown[X]=nil.
    sessionTokens[X] still T_A; inFlightSaves[X] NOT cleared.
T4  Autosave eventually completes (DataStore recovers).
    §6.3 Step 1: inFlightSaves[X] decremented → 0.
    §6.3 Step 2: sessionTokens[X]==T_A==capturedToken → identity check passes. ✅
    §6.3 Step 3: confirmedSessionLoss=false (token matched in DataStore) → skip.
    §6.3 Step 4: playerState[X]=="abandoned" AND inFlightSaves[X]==0
    → sessionTokens[X]=nil; playerState[X]=nil. userId now eligible for rejoin.
T5  LOCK_TTL expires (60s from last DataStore write; may be later if a refresh completed
    after T1 — see §7.5). Session available to other servers. ✅
Data integrity: autosave snapshot written (T4); playerState cleared (T4). PASS
```

**Timeline G: PlayerRemoving owns; drain times out; BindToClose observes; must not report false completion (NEW — Revision 9, D-17)**

```
T0  Autosave: savePlayer(X); capturedToken=T_A; inFlightSaves[X]=1; UpdateAsync stalled.
T1  PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; drain wait starts.
    (sessionTokens[X] NOT cleared.)
T2  BindToClose fires. task.spawn → disconnectPlayer(X) → shuttingDown[X]==true →
    Phase 1: while shuttingDown[X] do task.wait(0.05) end → loops.
T3  DRAIN_DEADLINE (5s) exceeded. Owner: state→"abandoned"; shuttingDown[X]=nil; return.
    inFlightSaves[X] still 1; sessionTokens[X] still T_A.
T4  Phase 1 exits (shuttingDown nil).
    Phase 2: (inFlightSaves[X] or 0) = 1 > 0 → while loop starts.
    disconnectCount NOT decremented. BindToClose outer loop still running. ✅
T5  Autosave UpdateAsync completes. §6.3: inFlightSaves[X]→0; identity check passes;
    state=="abandoned" AND counter==0 → sessionTokens[X]=nil; playerState[X]=nil.
T6  Phase 2 exits. Observer returns → disconnectCount -= 1 ✅
Expected: disconnectCount reflects actual save completion, not lifecycle exit. PASS

Broken (Revision 8) behaviour:
    T4: Phase 1 only → observer returned immediately → disconnectCount -= 1 fires while
    inFlightSaves[X] still 1 → BindToClose could exit before autosave committed. ← D-17
```

**Timeline H: BindToClose owns; drain times out; PlayerRemoving observes; same two-phase wait (NEW — Revision 9, D-17)**

```
T0  Autosave: savePlayer(X); capturedToken=T_A; inFlightSaves[X]=1; UpdateAsync stalled.
T1  BindToClose fires first: task.spawn → disconnectPlayer(X) → shuttingDown[X]=true; drain starts.
    (sessionTokens[X] NOT cleared.)
T2  PlayerRemoving fires: disconnectPlayer(X) → shuttingDown[X]==true →
    Phase 1: while shuttingDown[X] do task.wait(0.05) end → loops.
T3  DRAIN_DEADLINE exceeded. Owner (BindToClose): state→"abandoned"; shuttingDown[X]=nil; return.
    inFlightSaves[X] still 1; sessionTokens[X] still T_A.
T4  Phase 1 exits. Phase 2: inFlightSaves[X]=1 → Phase-2 wait loop.
T5  Autosave completes. §6.3: inFlightSaves[X]=0; identity passes; state=="abandoned"
    → sessionTokens[X]=nil; playerState[X]=nil.
T6  Phase 2 exits. PlayerRemoving observer returns. ✅
Expected: Same protocol regardless of which caller owns. PASS
```

**Timeline F: Old session T_A disconnects; player rejoins same server with T_B; stale T_A refresh completes (NEW — Revision 8, D-16)**

```
T0  refreshSession for X (token T_A captured): UpdateAsync in progress.
T1  PlayerRemoving: disconnectPlayer(X).
    state→"disconnecting"; activeLocks[X]=nil.
    (sessionTokens[X] NOT cleared in step 2.)
T2  disconnectPlayer normal path: drain→disconnectSave→releaseSession.
    state→"released"; step-7 cleanup:
    loadedData[X]=nil; lastRefresh[X]=nil; sessionTokens[X]=nil; shuttingDown[X]=nil;
    playerState[X]=nil.   ← enables rejoin
T3  Player rejoins same server. loadPlayer(X): playerState[X]==nil → allowed.
    New token T_B generated; state→"loading"→"active"; sessionTokens[X]=T_B.
T4  Stale T_A refresh UpdateAsync completes.
    result._session.token: depends on DataStore state.
    Case A: DataStore has T_B (T_B acquired) → result.token==T_B ≠ T_A → else branch.
            Dual check: playerState=="active" ✓ FIRST CHECK PASSES.
                        sessionTokens[X]==T_B ≠ T_A ← SECOND CHECK FAILS → return false. ✅
            T_B session unaffected.
    Case B: DataStore still has T_A (T_B load in progress, not yet written).
            Callback: current._session.token==T_A → match → writes since=T4 (refresh succeeds).
            result.token==T_A: success path dual check:
                playerState=="active" ✓; sessionTokens[X]==T_B ≠ T_A ← FAILS → return false. ✅
            lastRefresh[X] is NOT updated to stale T_A's refresh time. T_B session unaffected.
Expected: Old T_A refresh cannot invalidate, kick, or update state for T_B session. DESIGN: PASS
```

**Timeline I: Drain-timeout autosave completes; playerState cleared; same-server rejoin enabled (NEW — Revision 9, D-17)**

```
T0  Autosave: savePlayer(X); capturedToken=T_A; inFlightSaves[X]=1; UpdateAsync stalled.
T1  PlayerRemoving: disconnectPlayer(X) → drain timeout → state="abandoned"; shuttingDown[X]=nil.
    inFlightSaves[X] still 1; playerState[X]="abandoned"; sessionTokens[X]=T_A (preserved).
T2  BindToClose observer (Phase 2 wait) loops on inFlightSaves[X] > 0.
T3  DataStore recovers. Autosave UpdateAsync completes.
    §6.3 Step 1: inFlightSaves[X] decremented → 0.
    §6.3 Step 2: sessionTokens[X]==T_A==capturedToken → identity passes.
    §6.3 Step 3: confirmedSessionLoss=false → skip.
    §6.3 Step 4: playerState[X]=="abandoned" AND inFlightSaves==0
    → sessionTokens[X]=nil; playerState[X]=nil. ✅ userId now available for rejoin.
T4  BindToClose Phase-2 wait: (inFlightSaves[X] or 0) = (nil or 0) = 0 → exits.
    disconnectCount -= 1 ✅
T5  Player rejoins: loadPlayer(X): playerState[X]==nil → allowed. New session T_B starts.
Expected: playerState cleared only after save completes. Rejoin succeeds. BindToClose accurate. PASS
```

**Timeline J: BindToClose 25-second deadline reached with outstanding saves (NEW — Revision 9, D-17)**

```
T0  Server shutdown: PlayerRemoving fires for X, Y. Both have stalled autosaves.
T1  BindToClose fires: disconnectCount=2.
    Spawns observers for X and Y (PlayerRemoving owns both → observers in Phase-1/Phase-2 wait).
T2  X: PlayerRemoving lifecycle exits (drain timeout); shuttingDown[X]=nil.
    Observer X: Phase-2 wait starts; inFlightSaves[X]=1 > 0 → loops.
T3  Y: same situation; observer Y Phase-2 wait; inFlightSaves[Y]=1 > 0 → loops.
T4  os.clock() - bindToCloseStart >= 25s. BindToClose outer loop exits.
    disconnectCount == 2 > 0.
    warn("[DataManager] BindToClose: 25s deadline reached with 2 player(s) with
          outstanding saves or disconnect in progress.")
    BindToClose returns. Server proceeds to shut down.
T5  Spawned observers for X and Y are still running (Phase-2 wait).
    Roblox kills all scripts on server shutdown → saves are abandoned.
    Data since last committed save (autosave or prior) is lost for X and Y.
Expected: Warning logged; server shuts down within deadline; loss documented. PASS (degraded path)
```

**Timeline K: T_A autosave detects session loss after drain timeout; T_B not invalidated or kicked (NEW — Revision 10, D-20)**

```
T0  Autosave: savePlayer(X); capturedToken=T_A; inFlightSaves[X]=1; UpdateAsync stalled.
T1  PlayerRemoving: disconnectPlayer(X) → drain timeout → state="abandoned"; shuttingDown[X]=nil.
    inFlightSaves[X] still 1; sessionTokens[X]=T_A (preserved — D-20 fix).
T2  Another server S_B acquires X's session in DataStore (T_B_server token; T_A TTL expired).
T3  T_A autosave UpdateAsync completes.
    Callback: current._session.token==T_B_server ≠ T_A → callback returns nil.
    Result: confirmedSessionLoss=true.
    §6.3 Step 1: inFlightSaves[X] decremented → 0.
    §6.3 Step 2: sessionTokens[X]==T_A==capturedToken → identity check passes. ✅
    §6.3 Step 3: confirmedSessionLoss=true; playerState[X]=="abandoned" (NOT "active")
    → skip invalidation; warn "session ownership lost (state=abandoned); no kick needed."
    §6.3 Step 4: playerState[X]=="abandoned" AND inFlightSaves==0
    → sessionTokens[X]=nil; playerState[X]=nil. ✅
T4  Same-server player rejoins: playerState[X]==nil → loadPlayer allowed.
    T_B_server session in DataStore: acquisition checks TTL/released → may succeed or fail
    depending on T_B_server session status. No permanent block.
Expected: T_A confirmedSessionLoss in abandoned path → warn log; no invalidation; no kick; rejoin enabled. PASS

Broken (Revision 9) behaviour:
    T3: §6.3 no identity check: confirmedSessionLoss fires immediately.
    playerState[X]="invalidated" ← BUG (was "abandoned"; now "invalidated").
    §6.3 drain-timeout cleanup: playerState != "abandoned" → skip nil-clear.
    playerState[X] stays "invalidated" forever → same-server rejoin permanently blocked. ← D-20
```

**Timeline L: T_A autosave completes after T_B is fully active on same server; T_B identity check blocks T_A (NEW — Revision 10, D-20)**

```
Precondition: T_A session released normally; playerState[X]=nil; T_B loaded; state="active";
sessionTokens[X]=T_B; T_A autosave was in flight during T_A's normal lifecycle (edge: very late save).
T0  T_A autosave §6.3 completion fires.
T1  §6.3 Step 1: inFlightSaves[X] decremented → 0 (releases T_A's slot).
T2  §6.3 Step 2: sessionTokens[X]==T_B ≠ capturedToken(T_A) → stale completion → return false. ✅
    T_B's playerState, inFlightSaves, invalidated, and sessionTokens are all untouched.
Expected: Stale T_A save completion cannot modify T_B session state. PASS
Note: Per the §5.1 + §6.3 ordering invariant this scenario is structurally impossible
      (D-20 deep review, M-1):
      — Normal path: drain waits until inFlightSaves=0 (all T_A autosaves done);
        disconnectSave runs and decrements to 0; step 7 sets playerState=nil.
        By the time T_B can load, every T_A save has completed. No save is "very late."
      — Drain-timeout path: §5.1 blocks T_B until §6.3 Step 4 fires, which requires
        inFlightSaves=0. Step 4 sets playerState=nil in the same call that decremented
        the last counter slot. T_B starts only after that last save finished.
      In both paths: T_B is never active while a T_A save is in flight.
      If this scenario fired via a scheduler anomaly, Step 1 would decrement T_B's
      inFlightSaves counter — Phase-2 could then exit before T_B's save completes.
      Step 2 catches stale completions but cannot undo the decrement. The structural
      guarantee must hold. DT-4 (formal proof) and DT-5 (defence-in-depth) document this.
```

**Timeline M: Player leaves while `loadPlayer` UpdateAsync is in progress; presence check prevents ghost session (D-22)**

```
T0  PlayerAdded for X. game code calls loadPlayer(X).
    §5.1 guard: playerState[X]==nil → allowed. playerState[X]="loading".
    Token T_A generated. UpdateAsync yields.
T1  PlayerRemoving fires for X (player disconnected during load).
    disconnectPlayer(X): playerState[X]=="loading" ≠ "failed" ≠ "invalidated" ≠ "active" → returns.
    No lifecycle cleanup (session not yet activated; §5.6 not yet reached).
T2  T_A's UpdateAsync returns: result._session.token==T_A → acquisition confirmed.
    §5.6 presence check: player.Parent==nil → player has left.
T3  loadPlayer issues inline release for T_A session in DataStore: writes _session.released=true.
    Clears playerState[X]=nil (clears "loading" state).
    Returns nil to game code caller. ✅
T4  PlayerAdded game handler receives nil from loadPlayer.
    Player is no longer present (PlayerRemoving already fired) → no further action needed.
T5  Other servers: T_A session has released=true in DataStore → can acquire immediately.
Expected: No ghost "active" session created. Session released promptly. playerState cleared. DESIGN: PASS
```

**Timeline M-B: Player leaves and rejoins same server while original load is in progress (D-22 leave-and-rejoin)**

```
T0  PlayerAdded for X. loadPlayer(X): playerState[X]="loading". UpdateAsync yields.
T1  PlayerRemoving fires for X (player left).
    disconnectPlayer: playerState=="loading" → returns immediately (not "failed", not "invalidated", not "active").
T2  PlayerAdded for X (player rejoined same server before T_A's load completes).
    loadPlayer(X): playerState[X]=="loading" ≠ nil → §5.1 rejects.
    Returns nil to PlayerAdded handler. ✅
    Caller responsibility: game code detects player present but loadPlayer returned nil →
    kick player: "Data still loading from previous session. Please wait and rejoin."
T3  T_A's UpdateAsync returns: acquisition confirmed.
    §5.6 presence check: player.Parent==nil (original T_A player object; T_B is a different object).
    Inline release for T_A issued. playerState[X]=nil.
T4  T_B can now join any server and load successfully on the next connection attempt.
Expected: T_B blocked during T_A's active load; kicked with guidance; no ghost session;
         next rejoin (after T_A releases) succeeds. DESIGN: PASS
Caller responsibility: PlayerAdded handler must check if player is still present when
loadPlayer returns nil, and kick with an appropriate retry message.
```

**Timeline N: "invalidated" state PlayerRemoving cleanup; `inFlightSaves == 0` at PlayerRemoving (D-21)**

```
Precondition: Player X has state "active"; one autosave is in flight (inFlightSaves[X]=1).
T0  Autosave UpdateAsync completes. §6.3 Step 1: inFlightSaves[X] → 0.
    Step 2: sessionTokens[X]==T_A==capturedToken → identity passes.
    Step 3: confirmedSessionLoss=true; playerState[X]=="active" →
    playerState[X]="invalidated"; invalidated[X]=true; player kicked.
    Step 4: playerState=="abandoned"? NO → skip. (inFlightSaves[X] is 0.)
T1  PlayerRemoving fires (kick delivered). disconnectPlayer(X): playerState[X]=="invalidated".
    D-21 terminal cleanup: (inFlightSaves[X] or 0)==0 → immediate full cleanup.
    Clears: loadedData, invalidated, activeLocks, lastRefresh, sessionTokens, inFlightSaves → nil.
    Sets: playerState[X]=nil.
T2  Same-server rejoin: loadPlayer(X): playerState[X]==nil → allowed. ✅
Expected: playerState cleared by disconnectPlayer terminal cleanup;
         same-server rejoin enabled. DESIGN: PASS
```

**Timeline N-B: "invalidated" state PlayerRemoving cleanup; `inFlightSaves > 0` at PlayerRemoving (D-21 deferred path)**

```
Precondition: Two autosaves in flight (inFlightSaves[X]=2).
T0  Autosave 1 §6.3 Step 1: inFlightSaves[X] → 1.
    Step 2: identity passes. Step 3: session loss → playerState[X]="invalidated"; player kicked.
    Step 4: playerState=="abandoned"? NO. inFlightSaves==0? NO (still 1). Skip.
T1  PlayerRemoving fires. disconnectPlayer(X): playerState[X]=="invalidated".
    D-21 terminal cleanup: (inFlightSaves[X] or 0)==1 > 0 → partial cleanup:
    Clears: loadedData, invalidated, activeLocks, lastRefresh → nil.
    Sets: playerState[X]="abandoned" (enables §6.3 Step 4 reuse).
    Returns immediately (no shuttingDown set; not lifecycle owner).
T2  Autosave 2 UpdateAsync completes. §6.3 Step 1: inFlightSaves[X] → 0.
    Step 2: sessionTokens[X]==T_A==capturedToken → identity passes.
    Step 3: confirmedSessionLoss=true; playerState[X]=="abandoned" (NOT "active") →
    skip invalidation; warn "session ownership lost (state=abandoned); no kick needed."
    Step 4: playerState[X]=="abandoned" AND inFlightSaves[X]==0 →
    sessionTokens[X]=nil; inFlightSaves[X]=nil; playerState[X]=nil. ✅
T3  Same-server rejoin: loadPlayer(X): playerState[X]==nil → allowed. ✅
Expected: Deferred cleanup via §6.3 Step 4; same-server rejoin enabled after last save completes. DESIGN: PASS
```

**Timeline O: "failed" state PlayerRemoving cleanup; same-server rejoin enabled (D-21)**

```
T0  loadPlayer(X): all LOAD_RETRIES exhausted (DataStore unavailable).
    playerState[X]="failed"; invalidated[X]=true; player kicked.
    (sessionTokens, loadedData, activeLocks, inFlightSaves: all nil — session never activated.)
T1  PlayerRemoving fires. disconnectPlayer(X): playerState[X]=="failed".
    D-21 terminal cleanup: playerState[X]=nil; invalidated[X]=nil.
    Returns immediately.
T2  Same-server rejoin: loadPlayer(X): playerState[X]==nil → allowed. ✅
Expected: playerState and invalidated cleared; same-server rejoin enabled. DESIGN: PASS
Note: If loadPlayer failed due to confirmed session loss (§5.5 line 2):
      playerState[X]="failed"; invalidated[X]=nil (not set in that path).
      Cleanup: playerState[X]=nil; invalidated[X]=nil (clearing nil is safe).
      Outcome identical. ✅
```

---

## 11. Retry and Recovery Summary

| Operation | DataStore error | Confirmed session loss | Success |
|---|---|---|---|
| `loadPlayer` | Retry 3×, 2s/4s backoff; kick after all fail | Kick immediately; no retry | Build data from returned record |
| `savePlayer` | Retry 3×, 2s/4s backoff | If state=="active": `invalidated[userId]=true`; kick; no retry. If state=="abandoned": log warning; drain-timeout cleanup clears state. | Return true |
| `refreshSession` | Log; check elapsed vs LOCK_TTL | `invalidated[userId]=true`; kick (dual identity check: only if still active AND token matches) | Update `lastRefresh` (dual identity check applies) |
| `disconnectPlayer` / `disconnectSave` | TTL path if drain deadline exceeded; "abandoned" if disconnectSave fails or all retries exhausted | disconnectSave detects session loss → state → "abandoned"; skips releaseSession | State → "released" |
| `releaseSession` | Retry 3×; state → "abandoned" on all DataStore errors exhausted | Token mismatch → state → "released" (session superseded) | State → "released" |

**Never treat unknown load result as new player:** A load succeeds only when `result._session.token == token`. All other outcomes (error, nil, different token) transition to "failed" / trigger a kick without populating `loadedData`.

---

## 12. Backward Compatibility

| Concern | Handling |
|---|---|
| `TycoonPlayerData_v1` name | Unchanged |
| Player key | `tostring(player.UserId)` — unchanged |
| Legacy records (no `_session`) | The absence of `_session` is treated as "no live lock" in the acquisition callback. All existing game fields preserved verbatim. `_session` is added to the record on first load. |
| `_session` exposure | Never in `loadedData[userId]`; never in `getData` return value; never passed to game logic |
| `TycoonSessionLocks_v1` | Removed entirely — no reference in revised design |
| Existing player progress | Merge-on-load: DEFAULT_DATA overwritten with saved values; `_session` stripped before merge |

---

## 13. Constants

| Constant | Value | Rationale |
|---|---|---|
| `LOCK_TTL` | 60 s | A lock not refreshed within 60 s is treated as stale |
| `LOCK_REFRESH` | 20 s | 3 misses before TTL expires; refresh well inside TTL window |
| `LOAD_RETRIES` | 3 | 3 attempts; total wait up to 6 s |
| `LOAD_BACKOFF` | 2 s | 2 s / 4 s between attempts |
| `SAVE_RETRIES` | 3 | Same pattern |
| `SAVE_BACKOFF` | 2 s | 2 s / 4 s between attempts |
| `RELEASE_RETRIES` | 3 | Best-effort release; TTL is the safety net if all fail |

---

## 14. Files Requiring Changes

### `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` — rewrite

| Item | Change |
|---|---|
| `LockStore` / `TycoonSessionLocks_v1` | Remove |
| `loadFailed = {}` | Replace with `invalidated = {}` (broader scope; also covers session loss) |
| `playerState = {}` | Add (lifecycle state machine) |
| `sessionTokens = {}` | Add |
| `lastRefresh = {}` | Add |
| `inFlightSaves = {}` | Add (counts active UpdateAsync save calls per player; `disconnectPlayer` waits for 0 before saving/releasing) |
| `shuttingDown = {}` | Add (single-ownership flag for disconnect lifecycle; prevents competing saves/releases from PlayerRemoving and BindToClose) |
| `acquireLock()` | Remove — merged into `loadPlayer` callback |
| `releaseLock()` | Remove — replaced by internal `releaseSession()` (§8) |
| `refreshLock()` | Remove — replaced by `refreshSession()` (§7) |
| `loadPlayer()` | Rewrite per §5; concurrent load guard; GUID token; result-verification only |
| `savePlayer()` | Rewrite per §6; token+snapshot captured before async; `confirmedSessionLoss` outside callback |
| `disconnectSave()` | Add (new; internal; called only from `disconnectPlayer` after drain; accepts "disconnecting" state; uses explicit token+snapshot passed from disconnectPlayer) |
| `releaseSession()` | Rewrite as internal helper called only from `disconnectPlayer` after disconnectSave confirms save committed |
| `disconnectPlayer()` | Add (new; handles full drain→save→release lifecycle; called by both PlayerRemoving and BindToClose) |
| `getData()` | Update per §9.2; check `invalidated` and `playerState` |
| `PlayerRemoving` handler | Update per §10.2 — calls only `disconnectPlayer` |
| `BindToClose` handler | Update per §10.3 — calls only `disconnectPlayer` per player |
| `addCash`, `spendCash` | No change — both call `getData`; automatically guarded |

### `TycoonManager.server.lua`, `MapBuilder.server.lua` — no changes

---

## 15. Unresolved Technical Risks

**Risk 1 — `UpdateAsync` return value when callback returns nil (RESOLVED — confirmed by official documentation)**

Official Roblox documentation (`GlobalDataStore:UpdateAsync`, last verified 2026-11-24) states: *"If the callback returns nil, the write operation is cancelled and the value remains unchanged."*

The write behavior is confirmed: no write occurs and the DataStore value is left unchanged. The specific return value of `UpdateAsync` itself when the callback returns nil is not explicitly documented (it may be nil, or it may be the existing record). The design handles both without falsely reporting success:

For saves (§6.3): success is confirmed only by `ok==true AND result._session.token==token`. The check for ownership loss is `ok==true AND (result==nil OR result._session.token~=token)`. If `UpdateAsync` returns nil (Behaviour A), `result==nil` triggers the loss path. If it returns the existing record (Behaviour B), `result._session.token` is another server's token, triggering the same loss path. Neither behaviour produces a false success.

For acquisition (§5.4): same structure — `result._session.token==token` required for success; all other non-error outcomes map to confirmed failure.

For refresh (§7.2): same structure — `result._session.token==token` required for success; both nil and wrong-token non-nil map to ownership loss.

For release (§8.3): a nil or wrong-token non-nil result means another server holds the session; the release is treated as effectively complete (we cannot release what we do not hold).

**Remaining runtime verification:** Confirm whether `UpdateAsync` returns nil or the existing record when the callback returns nil. This does not change the correctness logic above, but it confirms which of the two branches is exercised in practice (test T-07).

**Risk 2 — Roblox callback retry behaviour under partial write success**

The design assumes: if a write succeeds but the ack is lost, the retry's callback receives `current` = the already-written record (with our token). This is the standard distributed systems assumption for "at least once" write semantics. If Roblox's DataStore uses "at most once" semantics (never retries after a failed ack), the idempotent-retry path in the callback (§5.3: `ourRetry = sess.token == token`) is never exercised but is not harmful.

**Risk 3 — Studio `HttpService:GenerateGUID` availability (NON-ISSUE — downgraded)**

Official Roblox documentation (`HttpService:GenerateGUID`, verified 2026-11-24) shows this function carries only a `Write Parallel` capability tag with no `Network` capability, confirming it is a local UUID generation operation that does not require HTTP requests to be enabled. The premise that HTTP requests must be enabled in Studio was incorrect. The `pcall` fallback in §3 is harmless but not needed in practice. The fallback token is weaker (not cryptographically unique) but it will not execute during normal Studio or production use. Risk 3 is downgraded to a non-issue; the defensive `pcall` can be retained at no cost.

**Risk 4 — PlayerRemoving vs BindToClose ordering during shutdown**

Roblox does not guarantee that `PlayerRemoving` fires before `BindToClose`. The lifecycle state machine handles both orderings safely (§10.3), but this has not been verified in a live shutdown test.

**Risk 5 — deepCopy in save callback includes `_session`**

`loadedData[userId]` never contains `_session`. However, if any code path accidentally writes a `_session` key into `loadedData`, the save callback's `deepCopy(snapshot)` would include it, then `newRecord._session = current._session` would overwrite it — the DataStore write would still be correct. This is a defence-in-depth property; the primary protection is that `loadPlayer` strips `_session` before populating `loadedData`.

**Risk 6 — Overlapping save snapshots (resolved in Revision 5 for normal path)**

Revision 4 did not prevent two saves from being in flight simultaneously at disconnect time, creating a last-DataStore-write-wins race between different snapshots.

Revision 5 `disconnectPlayer` drains all in-flight autosaves (§10, step 3) before taking the disconnect snapshot (step 4). There is never more than one save in flight at any point in the disconnect lifecycle. The disconnect save's snapshot is always at least as recent as the last autosave's snapshot. The race condition is eliminated for the normal path.

**Remaining edge case:** In the drain-timeout TTL path (Timeline E), the autosave is still in-flight when `disconnectPlayer` exits. The autosave may write its snapshot to DataStore after the disconnect. Since no release is issued and no competing disconnect save exists, there is no ordering conflict — the autosave's write is the final write. Session availability for other servers is delayed by TTL.

**Risk 7 — `disconnectPlayer` drain/save deadline may be too short for DataStore latency spikes**

The 5-second drain deadline covers in-flight autosaves; `disconnectSave` handles its own retries internally (up to SAVE_RETRIES × SAVE_BACKOFF). In severe DataStore outages, the drain deadline may be insufficient. The result is the TTL path (§10.1 step 3), which is safe but delays rejoin by up to LOCK_TTL (60s). Deadline values should be tuned against observed DataStore latency in production. Requires runtime verification.

**Risk 8 — In-flight `refreshSession` can extend the TTL anchor after `activeLocks` is cleared**

When `disconnectPlayer` clears `activeLocks[userId]`, a currently-running `refreshSession` task can still complete and write a new `_session.since` to DataStore (see §7.5). In the abandoned path (drain timeout), the TTL countdown starts from that late refresh write, not from when `activeLocks` was cleared.

**Worst-case delay:** If a refresh completes immediately after disconnect begins, another server must wait up to LOCK_TTL (60 s) from that refresh write before it can acquire. This is at most LOCK_REFRESH (~20 s) later than the theoretical earliest availability.

**Normal path is unaffected:** `releaseSession` writes `released=true`, and another server can acquire immediately regardless of `_session.since`.

**D-20 interaction (confirmed no change):** D-20 preserves `sessionTokens[userId]` through `disconnectPlayer` step 2, but this does not affect Risk 8. The refresh task already captured its token from `sessionTokens` before `disconnectPlayer` ran. D-20 changes what `sessionTokens` holds in memory; it does not change what the refresh callback captured or what it writes to DataStore. The dual identity check in §7.2 correctly prevents local state corruption but cannot prevent the DataStore `_session.since` write that already occurred inside the callback. Risk 8 is unaffected by D-20.

**Mitigation (optional, not in current design):** The refresh task could check `playerState[userId] == "active"` before the `UpdateAsync` call and return early if not. This reduces the window (skips the call if already disconnecting) but does not fully eliminate the risk — a yield inside `UpdateAsync` can still race with a `disconnectPlayer` call that starts after the check. This mitigation is not part of the current architecture.

---

## 16. Assumptions Requiring Verification

1. `PlayerStore:UpdateAsync` returns the value written by the callback (not the pre-write value) when the callback returns non-nil.
2. **RESOLVED:** When the callback returns nil, the write operation is cancelled and the DataStore value is left unchanged — confirmed by official Roblox documentation (`GlobalDataStore:UpdateAsync`). Both possible `UpdateAsync` return values in this case (nil, or the existing record) are handled without false success by the token-match check. See §15 Risk 1 for the updated analysis.
3. **CONFIRMED:** `HttpService:GenerateGUID(false)` does not require HTTP requests to be enabled — confirmed by its absence of a `Network` capability in official Roblox documentation. Available in both Studio and production servers without restriction. See §15 Risk 3 (downgraded to non-issue).
4. Roblox's cooperative scheduler ensures that a table assignment (`sessionTokens[userId] = nil`) is visible to all coroutines that read that table after the next yield point, with no partially-visible intermediate state.
5. `Players:GetPlayers()` during `BindToClose` execution does not include players whose `PlayerRemoving` has completed (player object removed from service). If it does include recently-removed players, the `loadedData[userId] == nil` guard safely rejects the save.
