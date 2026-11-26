# Architecture Decisions — Cash Empire Tycoon Phase 1

**Project:** Cash Empire Tycoon — PlayerDataManager replacement design
**Last updated:** 2026-11-26
**Specification:** Architecture Revision 18 (`docs/claude-reviews/phase-1/architecture.md`)

This document records confirmed architecture decisions, their rationale, rejected alternatives,
and unresolved decisions. All entries are sourced from project documentation. No decisions
or rationales are invented.

---

## Revision 18 Approval Status — Conflict Recorded

There is a documented conflict between two sources:

- **`docs/claude-reviews/phase-1/architecture.md` (Revision 18 header):** Status listed as
  "pending approval before implementation."
- **`docs/claude-reviews/phase-1/replacement-plan-review.md` (Executive Verdict):** States
  "APPROVE WITH CONDITIONS," treating the design as accepted.

These two descriptions are inconsistent. The more conservative reading — design reviewed,
conditions noted, explicit user approval status requires confirmation — is used throughout
this document. No approval record has been invented. The user must confirm whether Revision 18
is formally approved before implementation authorization is given.

---

## Confirmed Decisions

### AD-1 — Single-key fencing design (§1)

**Decision:** All lock and data operations use a single DataStore key (`TycoonPlayerData_v1`).
`_session` metadata is embedded inside the player's data record. `TycoonSessionLocks_v1` is
removed entirely.

**Rationale:** Roblox DataStores provide no cross-key atomic operations. The two-DataStore
design (D-1 in b05aa20) made it impossible to verify lock ownership at write time — the lock
could expire or be claimed between the lock check and the data write. Embedding `_session`
in the same key makes every meaningful operation (acquire, save, refresh, release) a single
`UpdateAsync` call.

**Rejected alternative:** Two-DataStore architecture (implemented in b05aa20). Rejected as
D-1 CRITICAL defect.

**Sources:** `architecture.md §1`; `implementation-report.md D-1`

---

### AD-2 — Fencing token generated outside UpdateAsync callback (§3, §5.2)

**Decision:** The fencing token (`HttpService:GenerateGUID(false)`) is generated once per
`loadPlayer` call, outside the UpdateAsync callback, before the callback is constructed. The
callback captures the token as a read-only closure variable and never mutates it.

**Rationale:** The UpdateAsync callback can be retried by Roblox. If `acquired = true` were set
inside the callback (D-3 in b05aa20), call 1 setting it true would persist to call 2 even if
call 2 returned nil (session taken). Generating the token outside and verifying acquisition
only from the return value eliminates this race.

**No pcall, no fallback for per-player fencing token (`GenerateGUID` at §5.2):** Confirmed
— `HttpService:GenerateGUID(false)` does not require HTTP requests enabled. It is a local
operation. A fallback would break the token-uniqueness invariant under known seeding
conditions. If `GenerateGUID` raises an unexpected error at §5.2 (per-player token
generation), the UDQ-3 failure protocol applies: `set playerState[userId] = "failed"`, kick
the player, return nil. Do not leave `playerState = "loading"`.

**GUID failure paths — two distinct scenarios:**

1. **Module-level `JOB_ID` generation (line 18, module load time):**
   `JOB_ID = game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false)`
   If this call fails, the error propagates at module load — before any `PlayerAdded`,
   `PlayerRemoving`, `BindToClose`, or autosave handler is registered. This is the documented
   "correct failure mode" (architecture §3). The module fails to load; all consumers receive
   the propagated error from their bare `require()` calls and abort.

2. **Per-player token generation (architecture §5.2, inside `loadPlayer`):**
   `token = HttpService:GenerateGUID(false)` is called once per `loadPlayer` invocation.
   If this call fails, the UDQ-3 failure protocol applies: set `playerState[userId] = "failed"`,
   kick the player, return nil. Do not leave `playerState = "loading"`.
   See `architecture.md §3`; `replacement-implementation-plan.md UDQ-3`.

These are independent failure paths with different scopes and different recovery requirements.

**Sources:** `architecture.md §3, §5.2, §15 Risk 3`; `implementation-report.md D-3, M-2`

---

### AD-3 — Acquisition verification from return value only (§5.4)

**Decision:** Acquisition is confirmed only when `ok == true AND result._session.token == token`.
A nil result or token mismatch is treated as confirmed session loss and triggers a kick without
retry. No closure variable (`sessionVerified`, `acquired`) is used for correctness-critical
verification.

**Rationale:** Closure mutation inside the callback persists across retries (D-3). Result
verification from the return value is the only approach that correctly reflects the final
DataStore state after all callback retries complete.

**Sources:** `architecture.md §5.4`; `implementation-report.md Issue 1`

---

### AD-4 — Single TTL-based availability rule (§5.3)

**Decision:** A session is available for acquisition if and only if it is absent, explicitly
released (`released = true`), or `(now - sess.since) >= LOCK_TTL`. A live session is blocked
if and only if `sess.token ~= token`. The job ID is not independently evaluated for blocking.

**Rationale:** A same-jobId guard unconditionally rejected sessions from the same job ID even
if TTL had expired (D-7). This contradicted test scenario DS-3 (expired same-jobId session
must be acquirable). The single TTL rule is the governing gate; job ID is irrelevant to
availability.

**Sources:** `architecture.md §5.3`; `implementation-report.md D-7`

---

### AD-5 — Save callback uses captured immutable token and snapshot (§6.1–6.2)

**Decision:** `savePlayer` captures `token = sessionTokens[userId]` and
`snapshot = deepCopy(loadedData[userId])` before the UpdateAsync call. The callback uses only
these two captured values — both immutable from that point. The callback reads no shared
mutable state (`loadedData`, `sessionTokens`).

**Rationale:** The UpdateAsync callback can be retried. If the callback read `loadedData[userId]`
directly (D-6), a concurrent `releaseSession` clearing `loadedData` during a retry would cause
the callback to write nil or error. Capturing an immutable snapshot beforehand eliminates this
race.

**Sources:** `architecture.md §6.1–6.2`; `implementation-report.md D-6`

---

### AD-6 — `disconnectSave` as separate internal function (§6.5)

**Decision:** A new internal function `disconnectSave(userId, player, token, snapshot)` handles
the disconnect-path save. It accepts only `"disconnecting"` state and uses explicitly passed
token and snapshot. Regular autosaves (`savePlayer`) reject `"disconnecting"` via the state
guard and may not be called in that state.

**Rationale:** `disconnectPlayer` transitions state to `"disconnecting"` and captures
`sessionTokens[userId]` as a local — but does not clear it in step 2 (D-20 fix). `savePlayer`
rejects `"disconnecting"` via its state guard. Without `disconnectSave`, the final disconnect
save would be silently skipped (D-14 CRITICAL).

**Sources:** `architecture.md §6.5`; `implementation-report.md D-14`

---

### AD-7 — Dual identity check in §7.2 / §7.3 refresh handlers (§7.2–7.3)

**Decision:** Before applying any refresh result to per-player state, both conditions must hold:
(1) `playerState[userId] == "active"`, and (2) `sessionTokens[userId] == token` (the captured
value). If either fails, the refresh is stale and must return false without modifying state.

**Rationale:** A single `playerState == "active"` check is insufficient. A player can disconnect
(T_A) and the same server can accept a rejoin (T_B, state = "active"). A stale T_A refresh
completing while T_B is active would pass the first check and incorrectly invalidate T_B's
session (D-16 CRITICAL). The second check (`sessionTokens == capturedToken`) catches this.

**Sources:** `architecture.md §7.2–7.3`; `implementation-report.md D-16`

---

### AD-8 — `sessionTokens` preserved through `disconnectPlayer` step 2 (§10.1 step 2)

**Decision:** `disconnectPlayer` does NOT clear `sessionTokens[userId]` in step 2.
`sessionTokens` is cleared in step 7 (normal / save-failed paths) or by `§6.3 Step 4`
(drain-timeout path).

**Rationale:** Clearing `sessionTokens` before the drain wait means that when a drain-timeout
autosave eventually completes in `§6.3`, its identity check (`sessionTokens[userId] == token`)
always finds nil — the check fails and state is never cleared, permanently blocking the userId
(D-20 CRITICAL). Preserving `sessionTokens` allows the identity check to work correctly in
all paths.

**Sources:** `architecture.md §6.3, §10.1`; `implementation-report.md D-20, R-30`

---

### AD-9 — Two-phase wait for observing caller in `disconnectPlayer` (§10.1 step 1)

**Decision:** When `disconnectPlayer` observes `shuttingDown[userId]` already set, it performs
a two-phase wait before returning: (1) `while shuttingDown[userId] do task.wait(0.05) end`,
then (2) `while (inFlightSaves[userId] or 0) > 0 do task.wait(0.05) end`. The
`disconnectCount` decrement in BindToClose fires only after both phases.

**Rationale:** A one-phase wait (Phase 1 only) exits when `shuttingDown` clears — but in the
drain-timeout path the lifecycle owner clears `shuttingDown` while `inFlightSaves` is still
> 0. The BindToClose observer would then decrement the counter prematurely and BindToClose
could exit while a save is still in flight (D-17 CRITICAL).

**Sources:** `architecture.md §10.1`; `implementation-report.md D-17, R-26`

---

### AD-10 — D-21 terminal state cleanup in `disconnectPlayer` (§10.1)

**Decision:** `disconnectPlayer` handles `"failed"` and `"invalidated"` terminal states before
the `"active"` guard. `"failed"` → immediate clear. `"invalidated"` with `inFlightSaves == 0`
→ immediate full clear. `"invalidated"` with `inFlightSaves > 0` → partial clear + state
transitions to `"abandoned"` (deferred cleanup via `§6.3 Step 4`).

**Rationale:** Without this cleanup, `playerState` persists as `"failed"` or `"invalidated"`
after `PlayerRemoving` fires (D-21 MEDIUM). `loadPlayer` §5.1 rejects any non-nil state, so
same-server rejoin would be permanently blocked until server restart.

**Sources:** `architecture.md §4, §10.1`; `implementation-report.md D-21`

---

### AD-11 — Option A for same-server rejoin during active load (§5.1)

**Decision:** When `loadPlayer` is called while `playerState[userId] == "loading"` (a previous
load is in progress), the new invocation (T_B) waits in a bounded loop
(`LOAD_WAIT_TIMEOUT = 30s`) until `playerState` becomes nil. T_B is not kicked during the
wait. When state becomes nil, a pre-load presence check (`player.Parent == nil`) runs before
`playerState = "loading"` is set.

**Rejected alternative (Option B):** Per-attempt generation tokens. Rejected because: (1) a
generation counter only supersedes T_A's in-memory state — T_B still cannot acquire the
DataStore session while T_A's lock is live; (2) adds shared mutable state; (3) provides no
correctness benefit over Option A.

**Limitation acknowledged:** When T_A's load fails (`playerState → "failed"`), T_B is kicked
once and must reconnect. Acceptable: DataStore unavailability affects subsequent loads equally.

**Sources:** `architecture.md §5.1`; `implementation-report.md D-22, Revision 15`

---

### AD-12 — D-23/D-24 Player-object identity guards (§10.1)

**Decision:** `activePlayers[userId]` stores the Player object at session activation (§5.6).
`disconnectPlayer` checks `activePlayers[userId] ~= player` for `"active"` state (D-23) and
`"invalidated"` state (D-24) before proceeding. Stale `PlayerRemoving` events from older
player objects are silently rejected.

**Rationale:** A stale `PlayerRemoving` from an older player object could otherwise proceed
using T_C's token from `sessionTokens[userId]`, save T_C's data, and release T_C's DataStore
session — leaving T_C with no data while still on the server.

**Sources:** `architecture.md §10.1`; `implementation-report.md D-23/D-24, Revision 17/18`

---

## Unresolved Decisions

### C-3 — §5.3 Idempotency check: Alt 1 vs Alt 2

**Status:** UNRESOLVED. Stage 2 implementation is blocked until this is resolved.

**Terminology source:** `docs/claude-reviews/phase-1/replacement-implementation-plan.md §5.3`
Decision Record.

**Decision required:** Whether to change the idempotent-retry check in the §5.3 acquisition
callback.

---

**Alt 1 — Token-only check (current accepted architecture):**

```lua
ourRetry = (sess.token == token)
```

No change to architecture §5.3. Relies on 2^-122 token collision probability from
`HttpService:GenerateGUID(false)`. If token uniqueness holds universally, the scenario where
two independent servers share the same token is structurally unreachable.

Required tests: BT-07a Scenario A (legitimate idempotent retry still works), BT-07b (Studio
token uniqueness confirmed).

---

**Alt 2 — Compound check with jobId (defense-in-depth):**

```lua
ourRetry = (sess.token == token AND sess.jobId == JOB_ID)
```

Makes the independent-server token-collision scenario (Scenario B) structurally impossible
even under token collision. Combined collision probability: 2^-244. Requires explicit update
to architecture §5.3 before Stage 2 implementation begins.

Required tests: BT-07a Scenario A (verify legitimate retry still passes with jobId check
added), BT-07a Scenario B (verify independent server with injected same token is rejected by
jobId check), BT-07b (Studio session uniqueness — both token and jobId differ).

---

**Alternative 3 — separately documented proposal:**

`docs/claude-reviews/phase-1/idempotency-gap-proposal.md` also documents **Alternative 3**
(Separate acquisition-request identity — a per-invocation RID field distinct from both
`token` and `JOB_ID`). That document analyzes all three alternatives and recommends Alt 2.
Alternative 3 is documented there as an option but was not carried forward into the
replacement plan's Decision Record, which lists only Alt 1 and Alt 2.

---

**Gap documented:** The token-uniqueness invariant is probabilistic (not structural). A
deterministic token collision from a different server (e.g., injected in a test) cannot be
distinguished from a legitimate retry under Alt 1. See
`docs/claude-reviews/phase-1/idempotency-gap-proposal.md` for the full analysis.

**Decision owner:** User.

**Conditions required to close:** Explicit written authorization from the user stating which
alternative is selected, with the rationale recorded in `replacement-implementation-plan.md`
Decision Record §5.3. If Alt 2 is selected, architecture.md §5.3 must also be updated before
Stage 2 implementation begins.

**Risk if Alt 1 selected:** The token-uniqueness assumption must hold universally, including
in any test fixture or environment that uses deterministic token injection.

**Risk if Alt 2 selected:** The added `sess.jobId == JOB_ID` check changes the
idempotent-retry gate. A legitimate retry from the same server always passes (jobId matches).
A retry from a different server is rejected even if the token matches.

**Sources:** `docs/claude-reviews/phase-1/replacement-implementation-plan.md §5.3 Decision
Record`; `docs/claude-reviews/phase-1/idempotency-gap-proposal.md`
