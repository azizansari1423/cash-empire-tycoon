# Phase 1 Architecture — Cash Empire Tycoon (Revision 3)

**Date:** 2026-11-24
**Scope:** `PlayerDataManager.lua` session locking design
**Status:** Pending approval before implementation

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

```
callback(current):
    now = os.time()

    if current ~= nil and current._session ~= nil:
        sess = current._session
        
        -- Check for active session owned by ANOTHER server
        anotherServer = sess.jobId ~= JOB_ID
                    and sess.released ~= true
                    and (now - (sess.since or 0)) < LOCK_TTL
        
        -- Check for idempotent retry: our specific token was already written
        ourRetry = sess.token == token    -- this token, this invocation
        
        if anotherServer and not ourRetry:
            return nil                    -- another server holds this; abort

        -- Explicit same-server / different-token guard:
        -- sess.jobId == JOB_ID but sess.token ~= token means another invocation
        -- of loadPlayer on THIS server holds the session. Treat identically to
        -- another server holding it: abort.
        if sess.jobId == JOB_ID and sess.token ~= token and not anotherServer:
            return nil                    -- different invocation on same server; abort

    -- Build new record: preserve all fields except _session
    newRecord = {}
    if current ~= nil:
        for k, v in current: if k ~= "_session": newRecord[k] = v

    newRecord._session = { jobId=JOB_ID, token=token, since=now, released=false }
    return newRecord
```

**Same-server different-token case:** If `current._session.jobId == JOB_ID` but `current._session.token ~= token`, a different invocation of `loadPlayer` on this server wrote that session. The callback returns nil — this invocation does not acquire the session. This prevents one `loadPlayer` invocation from silently overwriting another's session merely because the server IDs match.

**Idempotent retry:** If `current._session.token == token`, this invocation's write succeeded previously but the ack was lost. The callback re-writes the same record — idempotent. The returned result will satisfy `result._session.token == token`.

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

### 6.1 Guards

```
if playerState[userId] ~= "active" and playerState[userId] ~= "releasing":
    return false
if loadedData[userId] == nil:
    return false
```

The token is captured once, before any async operation:

```
local token = sessionTokens[userId]   -- captured here; valid even if sessionTokens cleared later
if token == nil: return false
```

### 6.2 Callback (no closure mutation for the correctness signal)

```
callback(current):
    if current == nil or current._session == nil:
        return nil                       -- session record gone; abort

    if current._session.token ~= token:  -- token is captured read-only from outside
        return nil                       -- session superseded; abort

    newRecord = deepCopy(loadedData[userId])
    newRecord._session = current._session  -- session metadata from DataStore, not memory
    return newRecord
```

The callback mutates no external state. It returns a record or nil. `token` is a read-only closure capture.

### 6.3 Verification without closure mutation

After `pcall(UpdateAsync)`:

| `ok` | `result` | Meaning | Action |
|---|---|---|---|
| false | — | DataStore error | Retry with backoff |
| true | `result._session.token == token` | Save confirmed | Return true |
| true | `result == nil` OR `result._session.token ~= token` | Confirmed session loss | Invalidate; kick; do NOT retry |

The outer function tracks whether the final `result == nil` case was reached via a flag set **outside the callback**:

```
local confirmedSessionLoss = false

for attempt = 1 to SAVE_RETRIES:
    local ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)
    
    if ok and result ~= nil and result._session ~= nil and result._session.token == token:
        return true                          -- confirmed save
    
    if ok and (result == nil or (result._session ~= nil and result._session.token ~= token)):
        confirmedSessionLoss = true
        break                                -- do NOT retry

    if not ok:
        warn("save attempt " .. attempt .. "/" .. SAVE_RETRIES)
        if attempt < SAVE_RETRIES: task.wait(SAVE_BACKOFF * attempt)

if confirmedSessionLoss:
    playerState[userId] = "invalidated"
    invalidated[userId] = true
    warn("Session ownership lost for " .. player.Name)
    player:Kick("Your session was claimed by another server.")
    return false

warn("All save retries exhausted for " .. player.Name)
return false
```

`confirmedSessionLoss` is set in the **outer function loop body**, not inside the UpdateAsync callback. It is set only after `pcall` succeeds and `result` indicates session loss — this is diagnostic logic about the return value, not a callback side effect.

### 6.4 Execution timeline — callback retry with ownership change (Issue 1 fix)

```
T0  Server A: savePlayer starts; token = sessionTokens[X] = T_A (captured locally)
T1  Callback call 1: current._session.token == T_A → match → write {data, _session:{T_A}}
T2  Write reaches DataStore; ack is lost (network partition)
T3  Server B: loadPlayer; UpdateAsync; callback sees {_session:{token:T_A}} — stale (TTL not met)
    ... T_A was just written, not yet expired — Server B waits or its lock check sees T_A as live
    (Assume: Server B waits LOCK_TTL and acquires after expiry, now has T_B)
T4  Roblox retries Server A's callback: current = {_session:{token:T_B}} (Server B took over)
T5  Callback call 2: current._session.token == T_B ≠ T_A → return nil
T6  UpdateAsync returns nil (callback returned nil on final invocation)
T7  Outer code: ok=true, result=nil → confirmedSessionLoss=true → break
T8  playerState = "invalidated"; player kicked; return false
T9  CORRECT: Server A's data is not saved; Server B's session is not disturbed
```

**Contrast with broken sessionVerified approach at T6–T8:**

```
T6  UpdateAsync returns nil
T7  Outer code: sessionVerified == true (set in T1, never cleared) → reports SUCCESS ← WRONG
T8  loadedData[X] believed saved; session believed held; no kick issued
    Server B's data may be overwritten on next autosave ← DATA CORRUPTION
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

```
ok, result = pcall(PlayerStore.UpdateAsync, userId, callback)

if ok and result ~= nil and result._session.token == sessionTokens[userId]:
    lastRefresh[userId] = os.time()           -- confirmed refresh
    return true

if ok and result == nil:
    -- Callback returned nil: session stolen
    playerState[userId] = "invalidated"
    invalidated[userId] = true
    warn("Session stolen for userId=" .. userId)
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

### 8.1 State transition and token capture

`releaseSession` may be called by `PlayerRemoving` or `BindToClose`. Only the first call does work; the second is a no-op via state check:

```
function releaseSession(userId):
    if playerState[userId] ~= "active":
        return                                -- already releasing, released, or not active
    
    playerState[userId] = "releasing"        -- transition BEFORE async operations
    activeLocks[userId] = nil                -- stop refresh loop from touching this player
    
    local token = sessionTokens[userId]      -- capture before clearing
    sessionTokens[userId] = nil              -- block new saves from verifying this token
    
    -- Any in-flight save that captured token before this point will proceed normally.
    -- Its callback verifies against the DataStore record (not sessionTokens).
    -- Any save starting AFTER this point: sessionTokens[userId] == nil → guard rejects it.
```

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
    if ok and result ~= nil and result._session ~= nil and result._session.released == true:
        released = true; break
    if ok and result == nil:
        -- Token mismatch: another server already holds the session. Nothing to release.
        released = true; break     -- effectively released from our perspective
    if not ok:
        warn("release attempt " .. attempt .. "/" .. RELEASE_RETRIES)
        if attempt < RELEASE_RETRIES: task.wait(SAVE_BACKOFF * attempt)

if not released:
    warn("Release failed for userId=" .. userId .. ". Lock will expire after " .. LOCK_TTL .. "s.")

playerState[userId] = "released"
```

If all release retries fail: the session will expire after LOCK_TTL seconds (60s) without refresh (since `activeLocks` was cleared in §8.1). This is the TTL safety net. State transitions to "released" regardless.

### 8.4 Why clearing `sessionTokens` before `UpdateAsync` is safe for in-flight saves

An in-flight save that **started before** `releaseSession` captures `token` as a local variable at save-start (§6.1). Its callback compares `current._session.token` to that captured local — not to `sessionTokens[userId]`. Clearing `sessionTokens[userId]` has no effect on the in-flight save's callback logic.

A save that **starts after** `sessionTokens[userId]` is cleared: the guard `local token = sessionTokens[userId]; if token == nil: return false` rejects it immediately. ✅

### 8.5 Execution timeline — save/release coordination (Issue 4 fix)

**Scenario: in-flight save + concurrent release**

```
T0  Autosave fires for Player X. savePlayer: state=="active" ✓; token=T_A captured; UpdateAsync yields
T1  PlayerRemoving fires. releaseSession: state=="active" → transition to "releasing"
    sessionTokens[X] = nil; token=T_A captured locally; UpdateAsync yields
T2  DataStore serializes per-key. First UpdateAsync to run:
    Autosave callback: current._session.token == T_A → match → writes {data, _session:{T_A, released:false}}
    result._session.token == T_A → save confirmed ✅
T3  Release UpdateAsync callback: current._session.token == T_A → match → marks released=true
    state → "released" ✅
T4  BindToClose fires. savePlayer: state=="released" → return false immediately ✅
    releaseSession: state ~= "active" → no-op ✅
Final DataStore state: {updated_data, _session:{T_A, released:true}} ✅
```

**Scenario: concurrent PlayerRemoving and BindToClose releases**

```
T0  PlayerRemoving: releaseSession → state "active" → "releasing"; sessionTokens cleared; T_A captured
T1  BindToClose: releaseSession → state == "releasing" → no-op; returns immediately ✅
T2  PlayerRemoving release UpdateAsync → state → "released" ✅
No duplicate release written to DataStore ✅
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
    savePlayer(player)         -- guards: state must be "active" or "releasing"; token check in callback
    releaseSession(userId)     -- transitions "active" → "releasing" → "released"; clears sessionTokens
    -- Cleanup all state tables
    loadedData[userId]  = nil
    invalidated[userId] = nil
    lastRefresh[userId] = nil
    playerState[userId] = nil
end)
```

After `loadedData[userId] = nil`, any subsequent `savePlayer` returning `false` from the loadedData guard. The state is already "released" or "released" at this point.

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

```
T0  Both PlayerRemoving and BindToClose start for Player X (state = "active")
T1  PlayerRemoving thread A: savePlayer starts; token T_A captured; state check passes; UpdateAsync yields
T2  BindToClose thread B: savePlayer starts; state check passes ("active"); token T_A captured; UpdateAsync yields
T3  DataStore serializes: Thread A's callback runs first; token match → writes data
T4  Thread B's callback runs: token match (T_A still in DataStore) → writes same data (idempotent) ✅
T5  Thread A: releaseSession → state "active" → "releasing"; sessionTokens cleared; UpdateAsync yields
T6  Thread B: releaseSession → state == "releasing" → no-op; returns immediately ✅
T7  Thread A release callback: token match → released=true; state → "released" ✅
Result: exactly one release written; two idempotent saves written; state = "released" ✅
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

**Risk 1 — `UpdateAsync` return value when callback returns nil**

If Roblox returns nil from `UpdateAsync` both when (a) the callback returned nil and (b) a DataStore error occurs after a nil-returning callback, the distinction `ok=true, result=nil` vs `ok=false` correctly handles both. However, if `UpdateAsync` returns the existing DataStore value (not nil) when the callback returns nil, the result-verification check `result._session.token == token` would need to also handle the case where `result._session.token ~= token` (another server's token) as "confirmed session loss."

**Mitigation:** The design handles both behaviours:
- `result == nil` → confirmed loss
- `result._session.token ~= token` → confirmed loss
Both branches are covered in §5.4 and §6.3.

**Risk 2 — Roblox callback retry behaviour under partial write success**

The design assumes: if a write succeeds but the ack is lost, the retry's callback receives `current` = the already-written record (with our token). This is the standard distributed systems assumption for "at least once" write semantics. If Roblox's DataStore uses "at most once" semantics (never retries after a failed ack), the idempotent-retry path in the callback (§5.3: `ourRetry = sess.token == token`) is never exercised but is not harmful.

**Risk 3 — Studio `HttpService:GenerateGUID` availability**

Requires HTTP requests enabled. The `pcall` fallback in §3 mitigates this. The fallback token is weaker (not cryptographically unique) but sufficient for Studio testing.

**Risk 4 — PlayerRemoving vs BindToClose ordering during shutdown**

Roblox does not guarantee that `PlayerRemoving` fires before `BindToClose`. The lifecycle state machine handles both orderings safely (§10.3), but this has not been verified in a live shutdown test.

**Risk 5 — deepCopy in save callback includes `_session`**

`loadedData[userId]` never contains `_session`. However, if any code path accidentally writes a `_session` key into `loadedData`, the save callback's `deepCopy(loadedData[userId])` would include it, then `newRecord._session = current._session` would overwrite it — the DataStore write would still be correct. This is a defence-in-depth property; the primary protection is that `loadPlayer` strips `_session` before populating `loadedData`.

---

## 16. Assumptions Requiring Verification

1. `PlayerStore:UpdateAsync` returns the value written by the callback (not the pre-write value) when the callback returns non-nil.
2. When the callback returns nil, `UpdateAsync` returns nil (not the existing value). If it returns the existing value, the result-token check still correctly detects session loss (`result._session.token ~= token`), so both behaviours are covered.
3. `HttpService:GenerateGUID(false)` is available without restriction in production Roblox servers (not just Studio with HTTP enabled).
4. Roblox's cooperative scheduler ensures that a table assignment (`sessionTokens[userId] = nil`) is visible to all coroutines that read that table after the next yield point, with no partially-visible intermediate state.
5. `Players:GetPlayers()` during `BindToClose` execution does not include players whose `PlayerRemoving` has completed (player object removed from service). If it does include recently-removed players, the `loadedData[userId] == nil` guard safely rejects the save.
