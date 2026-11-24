# Phase 1 Architecture Review — Cash Empire Tycoon

**Date:** 2026-11-24
**Scope:** `PlayerDataManager.lua` session locking design
**Status:** Defects identified; redesign recommended before production

---

## A. Why the Current Implementation Is Unsafe

### A1 — `savePlayer` writes without verifying session ownership

The lock (`TycoonSessionLocks_v1`) and the player data (`TycoonPlayerData_v1`) are separate DataStore keys. Roblox provides no cross-key atomic operations. The sequence that breaks it:

```
Server A: holds lock (timestamp = T)
Server A: network hiccup → lock refresh fails silently
  → lock TTL elapses; lock is now stale
Server B: acquireLock detects stale lock → takes ownership
Server A: 60-second autosave fires
  → savePlayer's UpdateAsync ignores _current, unconditionally writes
  → overwrites Server B's newly-claimed session data
```

The comment "This server holds the session lock and is authoritative" in the callback is aspirational, not enforced. Nothing inside the callback actually checks whether the lock is still held at write time.

### A2 — `refreshLock` failure is undetected

```lua
local function refreshLock(userId)
    pcall(function()
        LockStore:UpdateAsync(userId, function(current)
            if current and current.jobId == JOB_ID and not current.released then
                return { ... }
            end
            return nil   -- lock was stolen — but caller doesn't know
        end)
    end)
end
```

Two silent failure modes:
- `pcall` absorbs the error; `activeLocks[userId]` stays set; the server believes it holds a lock it may no longer hold.
- The callback returns nil (lock was stolen by another server); `pcall` succeeds, but the caller has no way to distinguish "refreshed" from "lock gone."

After either failure, `savePlayer` will still write, with no ownership guarantee.

### A3 — Closure mutation inside `UpdateAsync` callback

```lua
local acquired = false
LockStore:UpdateAsync(userId, function(current)
    ...
    acquired = true   -- side effect inside callback
    return lockRecord
end)
return acquired
```

Roblox may invoke the callback multiple times when the DataStore layer retries a failed write. The final value of `acquired` depends on which invocation ran last — not on what was actually persisted. The returned state is indeterminate.

### A4 — `GetAsync` has no retry on transient failure

A single DataStore timeout or HTTP 503 immediately sets `loadFailed` and kicks the player. Transient DataStore errors are common on Roblox during peak load. Phase 1 explicitly requires retry and failure handling.

### Root cause — no atomic lock + write

All four defects trace to the same root: using two separate DataStore keys for the lock and the data. Without per-key atomicity, the invariant "this server verifiably owns the session when it writes" cannot be enforced inside the write callback, regardless of how correctly the lock was acquired beforehand.

---

## B. Two Solutions Compared

### Solution 1 — ProfileStore

ProfileStore (loleris/ProfileStore, MIT license) is a maintained Roblox library that internally embeds the session lock in the player's DataStore record — one key, one `UpdateAsync`, atomic lock check + write.

**Compatibility with existing `TycoonPlayerData_v1` data:**

ProfileStore wraps player data in a container:
```lua
{
    Data     = { Cash = ..., ... },
    MetaData = { SessionJobId = ..., Created = ..., ... }
}
```

Existing keys in `TycoonPlayerData_v1` are raw tables: `{ Cash = ..., ... }`. ProfileStore has no built-in legacy-format detector. If pointed at a key containing a raw table, it treats the player as new (data loss).

A safe migration would need to:
1. Load the raw record via plain `GetAsync` on first join
2. Detect whether it is legacy or already wrapped
3. Write it back in ProfileStore format atomically

This migration must run once per player, at join time, before ProfileStore can safely serve that player. Implementing this migration atomically without risk of data loss during a failed migration step is non-trivial. If the detection step produces a false positive, game data could be silently zeroed.

**Verdict:** ProfileStore is technically the right foundation for a new project. For this game, using it without resolving the existing data format requires a migration step that is outside Phase 1 scope and carries meaningful data loss risk.

---

### Solution 2 — Custom Single-Key with Fencing Token (Recommended)

Merge the session lock INTO the player's existing `TycoonPlayerData_v1` record. All lock checks and data writes happen in one `UpdateAsync` on one key — atomic.

**On-disk record format (new, written at first load):**
```lua
{
    _session = { jobId = "...", token = "T1", since = timestamp, released = false },
    Cash     = 100,
    TotalEarned = 500,
    -- all other game fields unchanged
}
```

**Legacy format (all existing player records, no `_session` field):**
```lua
{ Cash = 100, TotalEarned = 500, ... }
```

The `_session` field is an internal sentinel, always stripped before data is returned to game code. Its presence or absence has no effect on game logic.

**Fencing token:** A string generated once per `loadPlayer` call (e.g., `JOB_ID .. "_" .. userId .. "_" .. os.time()`). Written into `_session.token` during load. Stored in `sessionTokens[userId]` in memory. During `savePlayer`, the callback reads the current `_session.token` from the DataStore and compares it to `sessionTokens[userId]`. Mismatch → return nil (abort). Match → write data, preserve `_session`.

The token check and the write are inside the same `UpdateAsync` callback — atomic.

**Backward compatibility:** On first load of a legacy record, the callback detects the absence of `_session`, adds it to the existing record, and writes it back. All existing game fields are preserved exactly. No migration script, no data loss risk.

---

## C. Recommendation

**Solution 2 — custom single-key with fencing token.**

| Factor | ProfileStore | Custom single-key |
|---|---|---|
| Atomic lock + write | ✅ | ✅ |
| Data migration required | ✅ Required | ❌ Not required |
| External dependency | ✅ | ❌ |
| Backward compatible | Only after migration | ✅ in-place, first load |
| Phase 1 scope fit | Exceeds (migration) | Fits exactly |
| Defect 1 resolved | ✅ | ✅ |
| Defect 2 resolved | ✅ | ✅ (token check supersedes refresh as safety net) |
| Defect 3 resolved | ✅ | ✅ (token generated outside callback) |
| Defect 4 resolved | ✅ | ✅ (withRetry wraps UpdateAsync) |

ProfileStore remains a valid future upgrade path once a DataStore migration is scoped and tested separately.

---

## D. How the Revised Design Handles Each Scenario

### Concurrent joins across servers

Both servers call `PlayerStore:UpdateAsync(userId, ...)`. The DataStore serializes concurrent writes per key. The first callback to execute checks for a live `_session` (none or stale), writes the lock with fencing token T1, and returns. The second callback sees T1 in `_session`, confirms `jobId ≠ JOB_ID`, not stale — returns nil. The second server's `loadPlayer` detects lock acquisition failed and kicks the player. ✅

### Lock refresh failure

Refresh updates `_session.since` in the data record. If it fails or the callback returns nil (session stolen), the server logs a warning. The lock's `since` timestamp goes stale after `LOCK_TTL` seconds — allowing another server to acquire the session. This is the correct behavior. The critical safety net is the fencing token: when Server A tries to save after Server B took ownership and wrote token T2, Server A's callback reads T2 from the DataStore, compares it to T1 in memory — mismatch — returns nil — no write. ✅

### Expired locks

Detected in `loadPlayer`'s UpdateAsync callback: `(os.time() - _session.since) >= LOCK_TTL`. Treated as available. The new server writes its token. Any subsequent write by the stale server is blocked by token mismatch. ✅

### Server crashes

The `_session` record remains in `TycoonPlayerData_v1` with `released = false`. After `LOCK_TTL` elapses, the next `loadPlayer` on any server treats the lock as stale and acquires it. Players may need to wait up to 60 seconds to rejoin. No data corruption. ✅

### Stale server saves

Server A's session was superseded (Server B acquired token T2). Server A's `savePlayer` fires:
```lua
PlayerStore:UpdateAsync(userId, function(current)
    if current._session.token ~= sessionTokens[userId] then
        -- current has T2, sessionTokens[userId] has T1 → mismatch → abort
        return nil
    end
    ...
end)
```
UpdateAsync is a no-op. Server B's data is not touched. Server A logs a warning. ✅

### PlayerRemoving and BindToClose races

`PlayerRemoving` saves, releases the session (`_session.released = true` in the data record), and clears `sessionTokens[userId]`, `loadedData[userId]`, `loadFailed[userId]`. After this, `BindToClose`'s `savePlayer` call finds `loadedData[userId] == nil` and returns false immediately — no double write. If BindToClose fires first, `Players:GetPlayers()` during BindToClose returns only currently-connected players; a player whose `PlayerRemoving` has already fired is not in that list. At most one write succeeds per session. ✅

### DataStore throttling and transient failures

- **Load:** `withRetry` wraps the `UpdateAsync` call, retrying up to 3 times with 2s/4s backoff. Only after all retries fail does `loadFailed` get set and the player get kicked.
- **Save:** `withRetry` wraps `UpdateAsync`, same 3-attempt / 2s/4s strategy.
- **Lock refresh:** best-effort, single attempt, pcall'd. Failures are logged. Non-fatal because the token check is the correctness guarantee.
✅

---

## E. Files and Functions Requiring Changes

### `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` — rewrite required

| Item | Change |
|---|---|
| `LockStore` / `TycoonSessionLocks_v1` | **Remove** — replaced by `_session` within `TycoonPlayerData_v1` |
| `acquireLock()` | **Remove** — merged into `loadPlayer`'s UpdateAsync callback |
| `releaseLock()` | **Replace** — sets `_session.released = true` inside `PlayerStore:UpdateAsync` |
| `refreshLock()` | **Replace** — updates `_session.since`; logs if callback returns nil (session stolen) |
| Lock refresh loop | **Keep** — calls new `refreshLock` |
| `loadPlayer()` | **Rewrite** — single `PlayerStore:UpdateAsync`; generates fencing token; `withRetry`; three-case load |
| `savePlayer()` | **Rewrite** — callback verifies `_session.token == sessionTokens[userId]` before writing |
| `sessionTokens = {}` | **Add** — new module-level table |
| `PlayerRemoving` | **Update** — also clears `sessionTokens[userId]` |
| `BindToClose` | No change — existing parallel-save logic is correct |
| `getData`, `addCash`, `spendCash` | No change — operate on `loadedData`, which has `_session` stripped |

### `RobloxTycoon/src/ServerScripts/TycoonManager.server.lua`

No changes required. The Phase 1 fixes (`plotsFolder`, nil guard after `loadPlayer`, `MapReady` wait) are correct and complete.

### `RobloxTycoon/src/ServerScripts/MapBuilder.server.lua`

No changes required. The `MapReady` signal is correct and complete.
