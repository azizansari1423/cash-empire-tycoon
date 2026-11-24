# Phase 1 Architecture — Cash Empire Tycoon (Revision 3)

**Date:** 2026-11-24
**Scope:** `PlayerDataManager.lua` session locking design
**Status:** Revision 4 — pending approval before implementation

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
          │  \
   session loss  releaseSession called
          │             │
          ▼             ▼
  ["invalidated"]  ["releasing"]
   ─── terminal          │
                 release UpdateAsync completes
                 (or all retries exhausted)
                          │
                          ▼
                     ["released"] ──── terminal
```

**State definitions:**

| State | Meaning | Allowed operations |
|---|---|---|
| nil / "idle" | Player not loaded | loadPlayer |
| "loading" | loadPlayer in progress | — (concurrent loadPlayer rejected) |
| "active" | Session held; data valid | getData, addCash, spendCash, savePlayer, releaseSession |
| "releasing" | Release in progress | savePlayer (in-flight only), releaseSession (no-op) |
| "released" | Session released | — (all operations blocked) |
| "failed" | Load failed | — (all operations blocked) |
| "invalidated" | Session stolen mid-game | — (all operations blocked) |

**Transition rules:**

- `nil → "loading"`: start of `loadPlayer`; rejected if state is "loading" (concurrent) or any non-nil state
- `"loading" → "active"`: after confirmed acquisition
- `"loading" → "failed"`: after all load retries exhausted
- `"active" → "releasing"`: start of `releaseSession`; first call wins (concurrent second call is a no-op)
- `"releasing" → "released"`: release UpdateAsync completes or all retries exhausted
- `"active" → "invalidated"`: confirmed session loss in `savePlayer` or `refreshSession`
- `"releasing" → "invalidated"`: release callback detects another server's token (no-op — still transition to "released" since we can't do anything further)

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

## 8. `releaseSession`

### 8.1 State transition, in-flight save wait, and token capture

`releaseSession` may be called by `PlayerRemoving` or `BindToClose`. Only the first call does work; the second is a no-op via state check.

**Ordering guarantee:** `releaseSession` waits for all in-flight saves to complete before proceeding with its own UpdateAsync. This ensures the final PlayerRemoving save (which runs just before `releaseSession`) is committed to DataStore before the session is released. Without this wait, a save UpdateAsync and the release UpdateAsync could be serialized in DataStore with the release running first, and the save re-opening the released session.

```
function releaseSession(userId):
    if playerState[userId] ~= "active":
        return                                -- already releasing, released, or not active
    
    playerState[userId] = "releasing"        -- transition BEFORE async operations
    activeLocks[userId] = nil                -- stop refresh loop from touching this player
    
    -- Block new saves: clearing sessionTokens causes the §6.1 guard to reject them
    local token = sessionTokens[userId]      -- capture before clearing
    sessionTokens[userId] = nil
    
    -- Wait for saves that captured the token before the clear above
    local waitDeadline = os.clock() + 5      -- 5 s deadline for in-flight saves to complete
    while (inFlightSaves[userId] or 0) > 0 and os.clock() < waitDeadline do
        task.wait(0.05)
    end
    if (inFlightSaves[userId] or 0) > 0 then
        warn("releaseSession: in-flight saves did not complete within deadline for userId=" .. userId)
        -- Proceed anyway; the token check in the release callback handles any ordering
    end
    
    -- Proceed with release UpdateAsync (see §8.3)
```

**Why clearing `sessionTokens` before waiting is safe:** Saves that have already captured `token` as a local variable continue normally — their callbacks do not read `sessionTokens`. Saves that start after the clear see `sessionTokens[userId] == nil` → `token == nil` → guard rejects them immediately. The `inFlightSaves` wait covers the saves already in-flight.

### 8.2 Callback

```
callback(current):
    if current == nil or current._session == nil: return nil
    if current._session.token ~= token: return nil  -- not our session; leave unchanged
    newRecord = deepCopy(current)
    newRecord._session.released = true
    return newRecord
```

### 8.3 Retry and failure

```
local released = false
for attempt = 1 to RELEASE_RETRIES (3):
    ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)
    if ok and result ~= nil and result._session ~= nil and result._session.released == true
            and result._session.token == token:
        released = true; break                        -- confirmed release
    if ok and result == nil:
        -- Callback returned nil: another server holds the session.
        -- Our session was not released; it has already been superseded.
        -- Treat as effectively released from our perspective.
        released = true; break
    if ok and result ~= nil and result._session ~= nil and result._session.token ~= token:
        -- Non-nil result with wrong token: same situation as nil — session superseded.
        released = true; break
    if not ok:
        warn("release attempt " .. attempt .. "/" .. RELEASE_RETRIES)
        if attempt < RELEASE_RETRIES: task.wait(SAVE_BACKOFF * attempt)

if not released:
    warn("Release failed for userId=" .. userId .. ". Lock will expire after " .. LOCK_TTL .. "s.")

playerState[userId] = "released"
```

If all release retries fail: the session will expire after LOCK_TTL seconds (60s) without refresh (since `activeLocks` was cleared in §8.1). This is the TTL safety net. State transitions to "released" regardless.

### 8.4 Execution timelines — save/release coordination

**Timeline A: autosave in-flight when PlayerRemoving fires**

```
T0  Autosave fires. savePlayer:
      state=="active" ✓
      token=T_A, snapshot=deepCopy(loadedData[X]) captured
      inFlightSaves[X] = 1
      UpdateAsync yields

T1  PlayerRemoving fires. PlayerRemoving calls savePlayer(X):
      state=="active" ✓ (save guard)
      token=T_A, snapshot=deepCopy(loadedData[X]) captured (may differ from T0 snapshot)
      inFlightSaves[X] = 2
      UpdateAsync yields

T2  PlayerRemoving calls releaseSession(X):
      state=="active" → "releasing"
      sessionTokens[X] = nil (blocks further saves)
      Wait: inFlightSaves[X] == 2 > 0 → task.wait(0.05) loop

T3  Autosave UpdateAsync completes:
      result._session.token == T_A → save confirmed ✅
      inFlightSaves[X] = 1; still > 0

T4  PlayerRemoving save UpdateAsync completes:
      result._session.token == T_A → save confirmed ✅
      inFlightSaves[X] = 0 → wait loop exits

T5  releaseSession proceeds: release UpdateAsync fires
      Callback: current._session.token == T_A → match → released=true
      result._session.token == T_A, released=true → confirmed ✅
      state → "released"

Final DataStore state: {PlayerRemoving_snapshot, _session:{T_A, released:true}} ✅
(PlayerRemoving save ran after autosave; its snapshot is more recent)
```

**Two overlapping saves with different snapshots — last-DataStore-write-wins:**

If autosave snapshot_T0 and PlayerRemoving snapshot_T1 are both in-flight and DataStore serializes autosave last, snapshot_T0 overwrites snapshot_T1. This is avoided by the `inFlightSaves` wait: `releaseSession` does not proceed to its release UpdateAsync until both saves complete. The PlayerRemoving save is started (by `PlayerDataManager.PlayerRemoving`) before `releaseSession` is called, so the PlayerRemoving save's snapshot is always at least as recent as the autosave's snapshot. After both saves commit, the last DataStore write is whichever UpdateAsync Roblox serialized second — an ordering that cannot be controlled. The difference between the two snapshots is at most one autosave interval (60s) of in-game earnings. This is the remaining unresolved risk (§15 Risk 6).

**Timeline B: concurrent PlayerRemoving and BindToClose releases**

```
T0  PlayerRemoving: releaseSession → state "active" → "releasing"
    Wait: inFlightSaves[X] == 0 → no wait needed
    sessionTokens[X] = nil; token=T_A captured; release UpdateAsync yields

T1  BindToClose: releaseSession → state == "releasing" → no-op; returns immediately ✅

T2  PlayerRemoving release UpdateAsync completes → state → "released" ✅
No duplicate release written to DataStore ✅
```

**Timeline C: BindToClose fires before PlayerRemoving completes**

```
T0  PlayerRemoving: savePlayer(X) starts; inFlightSaves[X]=1; UpdateAsync yields
T1  BindToClose: savePlayer(X) starts; inFlightSaves[X]=2; UpdateAsync yields
T2  BindToClose: releaseSession → state=="active"→"releasing"; wait: inFlightSaves[X]==2 > 0 → loops
T3  PlayerRemoving: releaseSession → state=="releasing" → no-op ✅
T4  T0 save UpdateAsync completes; inFlightSaves[X]=1
T5  T1 save UpdateAsync completes; inFlightSaves[X]=0 → wait exits
T6  BindToClose release UpdateAsync → released=true; state→"released" ✅
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

### 10.1 `PlayerRemoving`

```
Players.PlayerRemoving:Connect(function(player)
    local userId = tostring(player.UserId)
    -- Save first. This increments inFlightSaves and starts UpdateAsync.
    savePlayer(player)
    -- Release next. releaseSession waits for inFlightSaves[userId]==0 before
    -- proceeding to its own UpdateAsync, so the save always commits before the release.
    releaseSession(userId)
    -- Cleanup all state tables (state is "released" or terminal at this point)
    loadedData[userId]       = nil
    invalidated[userId]      = nil
    lastRefresh[userId]      = nil
    playerState[userId]      = nil
    inFlightSaves[userId]    = nil
end)
```

`releaseSession` waits for `inFlightSaves[userId] == 0` before issuing its own UpdateAsync (§8.1). This guarantees the PlayerRemoving save is committed to DataStore before the session is marked released.

### 10.2 `BindToClose`

```
game:BindToClose(function()
    local savingCount = 0
    for _, player in ipairs(Players:GetPlayers()) do
        savingCount += 1
        local userId = tostring(player.UserId)
        task.spawn(function()
            savePlayer(player)         -- state guard: "active" or "releasing" only
            releaseSession(userId)     -- second concurrent call is a no-op via state check
            savingCount -= 1
        end)
    end
    local deadline = os.clock() + 25
    while savingCount > 0 and os.clock() < deadline do
        task.wait(0.1)
    end
    if savingCount > 0 then
        warn("[DataManager] BindToClose: shutdown deadline with " .. savingCount .. " unsaved player(s)")
    end
end)
```

### 10.3 Race analysis — PlayerRemoving + BindToClose for the same player

This corresponds to Timeline C in §8.4 (BindToClose fires before PlayerRemoving completes). The lifecycle state machine and `inFlightSaves` wait ensure exactly one release is written.

```
T0  PlayerRemoving thread A: savePlayer → inFlightSaves[X]=1; UpdateAsync yields
T1  BindToClose thread B: savePlayer → inFlightSaves[X]=2; UpdateAsync yields
T2  Thread B: releaseSession → state "active"→"releasing"; tokenX=T_A; wait: inFlightSaves>0
T3  Thread A: releaseSession → state=="releasing" → no-op immediately ✅
T4  Thread A save completes → inFlightSaves[X]=1; still > 0 → Thread B still waiting
T5  Thread B save completes → inFlightSaves[X]=0 → Thread B wait exits
T6  Thread B: release UpdateAsync → token match → released=true → state→"released" ✅
Result: two saves committed; one release written; state = "released" ✅
```

---

## 11. Retry and Recovery Summary

| Operation | DataStore error | Confirmed session loss | Success |
|---|---|---|---|
| `loadPlayer` | Retry 3×, 2s/4s backoff; kick after all fail | Kick immediately; no retry | Build data from returned record |
| `savePlayer` | Retry 3×, 2s/4s backoff | `invalidated[userId]=true`; kick; no retry | Return true |
| `refreshSession` | Log; check elapsed vs LOCK_TTL | `invalidated[userId]=true`; kick | Update `lastRefresh` |
| `releaseSession` | Retry 3×; state → "released" regardless | No-op (not our session) | State → "released" |

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
| `inFlightSaves = {}` | Add (tracks count of active UpdateAsync save calls per player; `releaseSession` waits for this to reach 0) |
| `acquireLock()` | Remove — merged into `loadPlayer` callback |
| `releaseLock()` | Remove — replaced by `releaseSession()` (§8) |
| `refreshLock()` | Remove — replaced by `refreshSession()` (§7) |
| `loadPlayer()` | Rewrite per §5; concurrent load guard; GUID token; result-verification only |
| `savePlayer()` | Rewrite per §6; token captured before async; `confirmedSessionLoss` set outside callback |
| `getData()` | Update per §9.2; check `invalidated` and `playerState` |
| `PlayerRemoving` handler | Update per §10.1 |
| `BindToClose` handler | Update per §10.2 |
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

**Risk 6 — Overlapping save snapshots (last-DataStore-write-wins within one session)**

If autosave and PlayerRemoving save are both in-flight simultaneously, they carry different snapshots (snapshot_T0 and snapshot_T1 respectively, where T1 > T0). `releaseSession` waits for both saves to complete (§8.1) before releasing, ensuring neither save races with the release. However, DataStore serializes the two save UpdateAsync calls in an order that cannot be controlled: if autosave runs last in DataStore, it overwrites snapshot_T1 with snapshot_T0 (data from before the most recent `addCash` calls). The difference is at most one autosave interval (60s) of in-game earnings. Mitigation: the PlayerRemoving path could skip the autosave if one is already in-flight, using a debounce. This is deferred to implementation review.

---

## 16. Assumptions Requiring Verification

1. `PlayerStore:UpdateAsync` returns the value written by the callback (not the pre-write value) when the callback returns non-nil.
2. When the callback returns nil, `UpdateAsync` returns nil (not the existing value). If it returns the existing value, the result-token check still correctly detects session loss (`result._session.token ~= token`), so both behaviours are covered.
3. `HttpService:GenerateGUID(false)` is available without restriction in production Roblox servers (not just Studio with HTTP enabled).
4. Roblox's cooperative scheduler ensures that a table assignment (`sessionTokens[userId] = nil`) is visible to all coroutines that read that table after the next yield point, with no partially-visible intermediate state.
5. `Players:GetPlayers()` during `BindToClose` execution does not include players whose `PlayerRemoving` has completed (player object removed from service). If it does include recently-removed players, the `loadedData[userId] == nil` guard safely rejects the save.
