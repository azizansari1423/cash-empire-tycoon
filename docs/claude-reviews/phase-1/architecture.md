# Phase 1 Architecture — Cash Empire Tycoon (Revision 3)

**Date:** 2026-11-24
**Scope:** `PlayerDataManager.lua` session locking design
**Status:** Revision 5 — pending approval before implementation

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

**Studio fallback:** `HttpService:GenerateGUID` requires HTTP requests enabled in Studio. A `pcall` wraps the call; on failure a fallback `tostring(math.random(1e15)) .. "_" .. JOB_ID` is used. This is documented as a manual step in the test plan.

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
| "disconnecting" | Disconnect lifecycle in progress | savePlayer (in-flight only, via inFlightSaves counter) |
| "released" | Session explicitly released in DataStore | — (all operations blocked) |
| "abandoned" | Disconnect deadline exceeded; session expires by TTL | — (all operations blocked) |
| "failed" | Load failed | — (all operations blocked) |
| "invalidated" | Session stolen mid-game | — (all operations blocked) |

**Transition rules:**

- `nil → "loading"`: start of `loadPlayer`; rejected if state is non-nil
- `"loading" → "active"`: after confirmed acquisition
- `"loading" → "failed"`: after all load retries exhausted
- `"active" → "disconnecting"`: start of `disconnectPlayer`; first caller wins (see §10)
- `"disconnecting" → "released"`: saves drained, disconnect save committed, release UpdateAsync confirmed
- `"disconnecting" → "abandoned"`: drain or save deadline exceeded; no release UpdateAsync issued
- `"active" → "invalidated"`: confirmed session loss in `savePlayer` or `refreshSession`

**Cleanup:** On `PlayerRemoving`, all state tables (`playerState`, `loadedData`, `sessionTokens`, `activeLocks`, `lastRefresh`) are cleared after save and release complete.

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

---

## 6. Save (`savePlayer`)

### 6.1 Guards and immutable snapshot

All values the callback needs must be captured before the UpdateAsync call. The callback must not read any shared mutable state (`loadedData`, `sessionTokens`) because those tables can be cleared by `releaseSession` while the callback is mid-execution or being retried.

```
if playerState[userId] ~= "active" and playerState[userId] ~= "releasing":
    return false
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

**Two concurrent saves with different snapshots:** If autosave captures snapshot_T0 and PlayerRemoving save captures snapshot_T1 (after a `addCash` call between them), both UpdateAsync calls are in-flight simultaneously. DataStore serializes them: whichever callback runs last in DataStore wins. If the autosave runs last, it writes snapshot_T0 (the earlier data). This is a potential last-write-wins race between overlapping saves. The mitigation is `releaseSession` waiting for in-flight saves to complete before proceeding (§8.1), so the final PlayerRemoving save always runs after all concurrent autosaves complete, and the most recent snapshot is what gets released.

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

inFlightSaves[userId] = math.max(0, (inFlightSaves[userId] or 1) - 1)  -- decrement always

if confirmedSessionLoss:
    playerState[userId] = "invalidated"
    invalidated[userId] = true
    warn("Session ownership lost for " .. player.Name)
    player:Kick("Your session was claimed by another server.")
    return false

if not saveSucceeded:
    warn("All save retries exhausted for " .. player.Name)
return saveSucceeded
```

`confirmedSessionLoss` and `saveSucceeded` are set in the outer loop body, not inside the callback. The in-flight counter is decremented unconditionally so `releaseSession` is never blocked by a save that errored out silently.

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

T7  inFlightSaves[X] decremented to 0
T8  playerState = "invalidated"; invalidated[X]=true; player kicked; return false
T9  CORRECT: Server A's snapshot is not written; Server B's session is not disturbed

ALSO CORRECT: snapshot was captured before the UpdateAsync call.
Even if loadedData[X] is cleared at T1 by a concurrent releaseSession, the
callback at T1 and T4 uses only `snapshot` and `token` — both are unaffected. ✅
```

---

## 7. `refreshSession`

### 7.1 Callback

The callback updates `_session.since` to prevent TTL expiry. It verifies ownership from the returned record — no closure mutation.

```
callback(current):
    if current == nil or current._session == nil: return nil
    if current._session.token ~= sessionTokens[userId]:  return nil
    newRecord = deepCopy(current)
    newRecord._session.since = os.time()
    return newRecord
```

### 7.2 Verification after UpdateAsync

Success is confirmed only when `result._session.token == sessionTokens[userId]`. Every other non-error outcome is treated as ownership loss: this includes `result == nil` (callback returned nil) and `result ~= nil but result._session.token ~= sessionTokens[userId]` (callback returned nil and UpdateAsync returned the existing record with another server's token — see §15 Risk 1).

```
local token = sessionTokens[userId]  -- capture before UpdateAsync; stable reference
ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)

if ok:
    if result ~= nil and result._session ~= nil and result._session.token == token:
        lastRefresh[userId] = os.time()       -- confirmed refresh
        return true
    else:
        -- result == nil (callback returned nil) OR
        -- result._session.token ~= token (non-nil result, wrong token)
        -- Both indicate ownership loss.
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

### 7.3 Persistent refresh failure handling

The refresh loop tracks `lastRefresh[userId]`. On each failure:

```
if os.time() - (lastRefresh[userId] or 0) > LOCK_TTL:
    -- Lock has certainly expired; treat as stolen
    -- Apply same path as confirmed session loss above
    playerState[userId] = "invalidated"
    invalidated[userId] = true
    kick(...)
```

A single transient failure does not trigger a kick if `os.time() - lastRefresh < LOCK_TTL` (the lock has not yet expired).

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

---

## 8. Session Release — Internal Helper

`releaseSession` is an **internal helper** called only from `disconnectPlayer` (§10), and only after `disconnectPlayer` has confirmed `inFlightSaves[userId] == 0`. It never waits for saves internally; that is `disconnectPlayer`'s responsibility.

### 8.1 Precondition

`releaseSession` is called only when:
- `playerState[userId] == "disconnecting"` (set by `disconnectPlayer`)
- `inFlightSaves[userId] == 0` (confirmed by `disconnectPlayer` before calling)
- `sessionTokens[userId]` has been cleared (set to nil by `disconnectPlayer` to block new saves before the drain wait)

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
    activeLocks[X]=nil; captured token=T_A; sessionTokens[X]=nil.
T1  Drain wait: inFlightSaves[X]==0 → no wait (no autosave in flight). Pass.
T2  Disconnect save: savePlayer(X); snapshot=deepCopy(loadedData[X]); inFlightSaves[X]=1.
T3  Disconnect save UpdateAsync completes:
    result._session.token==T_A → confirmed ✅; inFlightSaves[X]=0.
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
    if playerState[userId] ~= "active" and playerState[userId] ~= "releasing" then return nil end
    return loadedData[userId]
```

`addCash` and `spendCash` both call `getData` → automatically return nil or false when `invalidated` or state is not "active"/"releasing". No additional changes required in those functions.

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

All disconnect logic is centralised in `disconnectPlayer`. Both `PlayerRemoving` and `BindToClose` call it. A `shuttingDown[userId]` flag ensures only one caller owns the lifecycle; the other returns immediately without competing saves or releases.

### 10.1 `disconnectPlayer` — unified shutdown lifecycle

The lifecycle enforces a strict sequential order: drain autosaves → disconnect save → release. Each step must complete before the next begins. If any deadline is exceeded, the session is not released in DataStore; it expires by TTL instead, and state transitions to "abandoned".

```
-- shuttingDown[userId] = nil | true  (guards single ownership)
-- DRAIN_DEADLINE = 5 s  (time to wait for in-flight autosaves)
-- SAVE_DEADLINE  = SAVE_RETRIES * (SAVE_BACKOFF * SAVE_RETRIES + 1) + 2  (~12 s, covers all retries)

function disconnectPlayer(userId, player):
    -- 1. Single-owner guard
    if shuttingDown[userId]: return                  -- another caller is handling this player
    if playerState[userId] ~= "active": return       -- not in a state we can disconnect
    shuttingDown[userId] = true
    playerState[userId] = "disconnecting"
    
    -- 2. Stop refresh and block new saves
    activeLocks[userId] = nil                        -- refresh loop stops iterating this player
    local token = sessionTokens[userId]
    sessionTokens[userId] = nil                      -- §6.1 guard rejects all new saves
    
    -- 3. Drain in-flight autosaves
    --    Any autosave that captured token before step 2 is in flight.
    --    Wait for it to complete (decrement inFlightSaves) before proceeding.
    local drainDeadline = os.clock() + DRAIN_DEADLINE
    while (inFlightSaves[userId] or 0) > 0 and os.clock() < drainDeadline:
        task.wait(0.05)
    
    if (inFlightSaves[userId] or 0) > 0:
        -- Autosave did not complete within deadline. Cannot guarantee snapshot ordering.
        -- Do NOT proceed with disconnect save or release.
        -- Session expires by TTL (activeLocks cleared → no refreshes → TTL countdown).
        playerState[userId] = "abandoned"
        warn("disconnectPlayer: autosave drain timeout for userId=" .. userId
             .. ". Session expires in ~" .. LOCK_TTL .. "s.")
        -- Cleanup: safe because autosave captured its own snapshot before this point.
        -- inFlightSaves is NOT cleared here; the autosave owns its counter slot.
        -- It will decrement inFlightSaves itself when its UpdateAsync completes.
        loadedData[userId]    = nil
        invalidated[userId]   = nil
        lastRefresh[userId]   = nil
        shuttingDown[userId]  = nil
        return
    
    -- 4. Disconnect save (inFlightSaves[userId] == 0 confirmed above)
    --    snapshot is taken inside savePlayer; only one save is in flight.
    savePlayer(player)
    
    -- 5. Wait for disconnect save to complete
    local saveDeadline = os.clock() + SAVE_DEADLINE
    while (inFlightSaves[userId] or 0) > 0 and os.clock() < saveDeadline:
        task.wait(0.05)
    
    if (inFlightSaves[userId] or 0) > 0:
        -- Disconnect save did not complete. Session expires by TTL.
        playerState[userId] = "abandoned"
        warn("disconnectPlayer: save deadline exceeded for userId=" .. userId
             .. ". Session expires in ~" .. LOCK_TTL .. "s.")
        loadedData[userId]    = nil
        invalidated[userId]   = nil
        lastRefresh[userId]   = nil
        inFlightSaves[userId] = nil   -- safe: save UpdateAsync is stuck; we give up on it
        shuttingDown[userId]  = nil
        return
    
    -- 6. Release session (saves confirmed drained; inFlightSaves[userId] == 0)
    releaseSession(userId, token)    -- internal helper; see §8
    
    -- 7. Cleanup (all async operations complete)
    loadedData[userId]    = nil
    invalidated[userId]   = nil
    lastRefresh[userId]   = nil
    inFlightSaves[userId] = nil
    shuttingDown[userId]  = nil
    -- playerState already set to "released" or "abandoned" by releaseSession / step 5
```

**Why state tables are only cleared after all async operations complete:**

- Steps 3–5 each confirm `inFlightSaves[userId] == 0` before proceeding. By step 7, no UpdateAsync calls are outstanding.
- In the drain-timeout path (step 3 failure), `loadedData` is cleared but `inFlightSaves` is NOT — the in-flight autosave still holds a reference and will decrement it. Clearing `inFlightSaves` early would leave the counter at a stale value if the autosave later tries to decrement.
- In the save-deadline path (step 5 failure), `inFlightSaves` IS cleared: at this point we consider the save stuck and give up on it. It is a degraded path; the session expires by TTL.

### 10.2 `PlayerRemoving`

```
Players.PlayerRemoving:Connect(function(player)
    local userId = tostring(player.UserId)
    disconnectPlayer(userId, player)
end)
```

### 10.3 `BindToClose`

```
game:BindToClose(function()
    local disconnectCount = 0
    for _, player in ipairs(Players:GetPlayers()) do
        disconnectCount += 1
        local userId = tostring(player.UserId)
        task.spawn(function()
            disconnectPlayer(userId, player)
            disconnectCount -= 1
        end)
    end
    local deadline = os.clock() + 25
    while disconnectCount > 0 and os.clock() < deadline do
        task.wait(0.1)
    end
    if disconnectCount > 0 then
        warn("[DataManager] BindToClose: 25s deadline reached with " .. disconnectCount .. " player(s) pending")
    end
end)
```

### 10.4 Execution timelines

**Timeline A: PlayerRemoving fires, no autosave in flight**

```
T0  PlayerRemoving calls disconnectPlayer(X).
    shuttingDown[X]=true; state→"disconnecting"; activeLocks[X]=nil; token=T_A; sessionTokens[X]=nil.
T1  Drain: inFlightSaves[X]==0 → pass immediately.
T2  savePlayer(X): snapshot captured; inFlightSaves[X]=1; UpdateAsync yields.
T3  Disconnect save completes → inFlightSaves[X]=0.
T4  releaseSession(X, T_A): token match → released=true → state→"released" ✅
T5  Cleanup: loadedData[X]=nil; inFlightSaves[X]=nil; shuttingDown[X]=nil.
```

**Timeline B: Autosave in flight when PlayerRemoving fires**

```
T0  Autosave: savePlayer(X); snapshot_T0 captured; inFlightSaves[X]=1; UpdateAsync yields.
T1  PlayerRemoving: disconnectPlayer(X).
    shuttingDown[X]=true; state→"disconnecting"; token=T_A; sessionTokens[X]=nil.
T2  Drain: inFlightSaves[X]==1 > 0 → wait(0.05) loop.
T3  Autosave UpdateAsync completes; inFlightSaves[X]=0 → drain passes.
    (DataStore now has the autosave snapshot_T0.)
T4  savePlayer(X): snapshot_T1=deepCopy(loadedData[X]) captured (all mutations up to T4);
    inFlightSaves[X]=1; UpdateAsync yields.
T5  Disconnect save UpdateAsync completes; inFlightSaves[X]=0.
    DataStore: {snapshot_T1, _session:{T_A}} (snapshot_T1 ≥ snapshot_T0 by time ordering).
T6  releaseSession(X, T_A): released=true; state→"released" ✅.
T7  Cleanup.
```

No two saves are in flight simultaneously. The disconnect save always starts after any prior autosave completes. snapshot_T1 captures all data written between T0 (autosave capture) and T4 (disconnect capture). The final DataStore state is snapshot_T1, which is the most recent snapshot. ✅

**Timeline C: PlayerRemoving fires before BindToClose reaches same player**

```
T0  PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle runs.
T1  BindToClose iterates Players. If player X is in the list:
    disconnectPlayer(X) → shuttingDown[X]==true → returns immediately ✅
PlayerRemoving's lifecycle handles everything; BindToClose is a no-op for this player.
```

**Timeline D: BindToClose fires before PlayerRemoving has started disconnectPlayer**

```
T0  BindToClose: task.spawn → disconnectPlayer(X) → shuttingDown[X]=true; full lifecycle starts.
T1  PlayerRemoving: disconnectPlayer(X) → shuttingDown[X]==true → returns immediately ✅
BindToClose's lifecycle handles everything for this player.
```

**Timeline E: Autosave drain timeout — TTL path**

```
T0  Autosave: savePlayer(X); inFlightSaves[X]=1; UpdateAsync stalled (DataStore unavailable).
T1  PlayerRemoving: disconnectPlayer(X).
    state→"disconnecting"; sessionTokens[X]=nil.
T2  Drain: inFlightSaves[X]==1 > 0; wait loop.
T3  After DRAIN_DEADLINE (5s): inFlightSaves[X] still 1 → drain timeout.
    state→"abandoned"; loadedData[X]=nil; return.
    (inFlightSaves[X] NOT cleared; autosave owns its slot.)
T4  Autosave eventually completes (DataStore available again):
    inFlightSaves[X] decremented → 0.
    Save callback: current._session.token==T_A → data written.
    (Session not released; another server waits for TTL.)
T5  LOCK_TTL expires (60s from last refresh, since activeLocks cleared at T1).
    Session available to other servers. ✅
Data integrity: autosave snapshot written (T4); no release race. ✅
```

---

## 11. Retry and Recovery Summary

| Operation | DataStore error | Confirmed session loss | Success |
|---|---|---|---|
| `loadPlayer` | Retry 3×, 2s/4s backoff; kick after all fail | Kick immediately; no retry | Build data from returned record |
| `savePlayer` | Retry 3×, 2s/4s backoff | `invalidated[userId]=true`; kick; no retry | Return true |
| `refreshSession` | Log; check elapsed vs LOCK_TTL | `invalidated[userId]=true`; kick | Update `lastRefresh` |
| `disconnectPlayer` | TTL path if drain/save deadline exceeded; state → "abandoned" | (n/a — called on normal disconnect, not on session loss) | State → "released" |
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
| `releaseSession()` | Rewrite as internal helper called only from `disconnectPlayer` after saves confirmed drained |
| `disconnectPlayer()` | Add (new; handles full drain→save→release lifecycle; called by both PlayerRemoving and BindToClose) |
| `getData()` | Update per §9.2; check `invalidated` and `playerState` |
| `PlayerRemoving` handler | Update per §10.2 — calls only `disconnectPlayer` |
| `BindToClose` handler | Update per §10.3 — calls only `disconnectPlayer` per player |
| `addCash`, `spendCash` | No change — both call `getData`; automatically guarded |

### `TycoonManager.server.lua`, `MapBuilder.server.lua` — no changes

---

## 15. Unresolved Technical Risks

**Risk 1 — `UpdateAsync` return value when callback returns nil (UNRESOLVED — requires runtime verification)**

This is an open API behaviour question that cannot be resolved from documentation alone. Two possible behaviours exist:

- **Behaviour A:** `UpdateAsync` returns `nil` when the callback returns `nil` (no write). This is the commonly assumed behaviour.
- **Behaviour B:** `UpdateAsync` returns the existing DataStore value (the record it passed to the callback) when the callback returns `nil`.

**How the design handles both without falsely reporting success:**

For saves (§6.3): success is confirmed only by `ok==true AND result._session.token==token`. The check for ownership loss is `ok==true AND (result==nil OR result._session.token~=token)`. Under Behaviour A, `result==nil` triggers the loss path. Under Behaviour B, `result._session.token` is another server's token, triggering the same loss path. Neither behaviour produces a false success.

For acquisition (§5.4): same structure — `result._session.token==token` required for success; all other non-error outcomes map to confirmed failure.

For refresh (§7.2): same structure — `result._session.token==token` required for success; both nil and wrong-token non-nil map to ownership loss.

For release (§8.3): a nil or wrong-token non-nil result means another server holds the session; the release is treated as effectively complete (we cannot release what we do not hold).

**What must be verified at runtime:** Confirm whether `UpdateAsync` returns nil or the existing record when the callback returns nil. Record the Roblox DataStore API version at the time of verification. This does not change the correctness logic above, but it confirms which of the two branches is exercised in practice.

**Risk 2 — Roblox callback retry behaviour under partial write success**

The design assumes: if a write succeeds but the ack is lost, the retry's callback receives `current` = the already-written record (with our token). This is the standard distributed systems assumption for "at least once" write semantics. If Roblox's DataStore uses "at most once" semantics (never retries after a failed ack), the idempotent-retry path in the callback (§5.3: `ourRetry = sess.token == token`) is never exercised but is not harmful.

**Risk 3 — Studio `HttpService:GenerateGUID` availability**

Requires HTTP requests enabled. The `pcall` fallback in §3 mitigates this. The fallback token is weaker (not cryptographically unique) but sufficient for Studio testing.

**Risk 4 — PlayerRemoving vs BindToClose ordering during shutdown**

Roblox does not guarantee that `PlayerRemoving` fires before `BindToClose`. The lifecycle state machine handles both orderings safely (§10.3), but this has not been verified in a live shutdown test.

**Risk 5 — deepCopy in save callback includes `_session`**

`loadedData[userId]` never contains `_session`. However, if any code path accidentally writes a `_session` key into `loadedData`, the save callback's `deepCopy(snapshot)` would include it, then `newRecord._session = current._session` would overwrite it — the DataStore write would still be correct. This is a defence-in-depth property; the primary protection is that `loadPlayer` strips `_session` before populating `loadedData`.

**Risk 6 — Overlapping save snapshots (resolved in Revision 5 for normal path)**

Revision 4 did not prevent two saves from being in flight simultaneously at disconnect time, creating a last-DataStore-write-wins race between different snapshots.

Revision 5 `disconnectPlayer` drains all in-flight autosaves (§10, step 3) before taking the disconnect snapshot (step 4). There is never more than one save in flight at any point in the disconnect lifecycle. The disconnect save's snapshot is always at least as recent as the last autosave's snapshot. The race condition is eliminated for the normal path.

**Remaining edge case:** In the drain-timeout TTL path (Timeline E), the autosave is still in-flight when `disconnectPlayer` exits. The autosave may write its snapshot to DataStore after the disconnect. Since no release is issued and no competing disconnect save exists, there is no ordering conflict — the autosave's write is the final write. Session availability for other servers is delayed by TTL.

**Risk 7 — `disconnectPlayer` drain/save deadline may be too short for DataStore latency spikes**

The 5-second drain deadline and ~12-second save deadline are estimates based on SAVE_RETRIES and SAVE_BACKOFF constants. In severe DataStore outages, these may be insufficient. The result is the TTL path (§10.1 steps 3–5), which is safe but delays rejoin by up to LOCK_TTL (60s). Deadline values should be tuned against observed DataStore latency in production. Requires runtime verification.

---

## 16. Assumptions Requiring Verification

1. `PlayerStore:UpdateAsync` returns the value written by the callback (not the pre-write value) when the callback returns non-nil.
2. **UNVERIFIED:** When the callback returns nil, `UpdateAsync` behaviour is not confirmed. See §15 Risk 1. Both possible return values (nil, or the existing record) are handled without false success by the token-match check.
3. `HttpService:GenerateGUID(false)` is available without restriction in production Roblox servers (not just Studio with HTTP enabled).
4. Roblox's cooperative scheduler ensures that a table assignment (`sessionTokens[userId] = nil`) is visible to all coroutines that read that table after the next yield point, with no partially-visible intermediate state.
5. `Players:GetPlayers()` during `BindToClose` execution does not include players whose `PlayerRemoving` has completed (player object removed from service). If it does include recently-removed players, the `loadedData[userId] == nil` guard safely rejects the save.
