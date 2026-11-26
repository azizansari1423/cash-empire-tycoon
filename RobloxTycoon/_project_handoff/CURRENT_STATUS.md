# Current Project Status — Cash Empire Tycoon

**Project phase:** Phase 1 — Data persistence foundation review and replacement design
**Last updated:** 2026-11-26
**Review branch:** `claude-review/phase-1`
**Working branch:** `feature/ai-collaboration-workflow` (HEAD: `940520c`)

---

## 1. Revision 18 Approval Status — Conflict Recorded

There is a documented conflict between two sources:

- **`architecture.md` (Revision 18 header):** Status listed as "pending approval before
  implementation."
- **`replacement-plan-review.md` (Executive Verdict):** States "APPROVE WITH CONDITIONS,"
  treating the design as accepted.

**Conservative status used here:** Design reviewed; conditions noted; explicit user approval
status requires confirmation. This document does not resolve this conflict. The user must
confirm before implementation authorization is given.

---

## 2. Current Phase and Implementation Status

### Phase
Phase 1 — Design, review, and specification of the PlayerDataManager replacement.
Phase 2 implementation is **blocked** (see §6).

### Committed candidate: b05aa20

The committed candidate (`b05aa20` on `feature/phase-1-data-foundation`) was **NOT APPROVED**
due to the two-DataStore architecture (D-1 CRITICAL). Full findings in
`docs/claude-reviews/phase-1/candidate-b05aa20-review.md`.

### Current uncommitted working-tree implementation

The working tree file `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` has uncommitted
modifications relative to `b05aa20`. These changes are **not committed** and have not been
independently reviewed. The working tree currently contains:

| Item | Working-tree state |
|---|---|
| DataStore handles | Single `PlayerStore = DataStoreService:GetDataStore("TycoonPlayerData_v1")` — `LockStore` removed |
| `JOB_ID` generation | `game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false)` — Studio fallback present |
| State tables declared | 9 tables: `playerState`, `sessionTokens`, `activeLocks`, `lastRefresh`, `loadedData`, `inFlightSaves`, `shuttingDown`, `invalidated`, `activePlayers` |
| `loadPlayer` implementation | Still uses `PlayerStore:GetAsync` — legacy behavior; no `UpdateAsync` acquisition callback, no fencing token, no `playerState` state machine |
| `savePlayer` implementation | Still uses `PlayerStore:SetAsync` — unconditional; no token verification, no snapshot capture, no in-flight counter |
| `BindToClose` / `PlayerRemoving` | No `disconnectPlayer`, no `shuttingDown` guard, no two-phase drain |
| `Heartbeat` handler | Empty body present (`-- handled via periodic loop below`) |

**Assessment:** The working tree reflects a partial Stage 1 migration — the single-DataStore
handle and GUID JOB_ID fallback are present, and the nine state tables are declared, but
`loadPlayer` and `savePlayer` still use the legacy `GetAsync`/`SetAsync` pattern without
the fencing, snapshot, or lifecycle machinery specified in Revision 18. Stage 1 is neither
unstarted nor complete; it is in an intermediate uncommitted state.

This intermediate state **has not been committed, reviewed, or authorized**. It must not be
treated as approved for deployment or as a basis for Stage 2.

### Replacement implementation plan

| Item | Status |
|---|---|
| Replacement implementation plan | APPROVE WITH CONDITIONS (independent review — see approval conflict §1) |
| Stage 1 implementation authorization | Not yet given by the user |
| Stages 2–5 | Blocked by C-3 and by Stage 1 prerequisite |

---

## 3. Verified Runtime Test Results

**No test results have been formally captured in `test-results.md`.** All scenario analyses
in that file are design-level only (labeled "DESIGN: PASS" — not observed runtime behavior).

**First Studio execution (user-reported, 2026-11-26):**

The user reported an execution attempt in Roblox Studio. This execution was communicated via
the ChatGPT project conversation and has not been formally captured in `test-results.md`. The
raw Roblox Studio Output log has not been attached or reproduced in the formal test record.
Assertion counts and outcomes listed below are based solely on the user's report and are not
independently established by the formal test record.

| Test | User-reported outcome | Notes |
|---|---|---|
| T-stage1-01 | **FAIL** (user-reported) — "You must publish this place to the web to access DataStore" | DataStore access not enabled in unpublished blank place. User-reported: all assertions after assertion A not reached. Not verified by formal Output record. |
| RP-T-11 | **PASS 18/18** (user-reported, Part 2 logic assertions) | Part 1 source fragments: unavailable (PluginSecurity restriction, as expected). User-reported count only — not verified by formal Output record. Classification: LOGIC TEST ON REPLICATED COPY ONLY — does not validate the production function directly. |
| T-guid-B | **FAIL** (user-reported) — Roblox returned "Requested module experienced an error while loading" | User-reported: Roblox wrapped the fixture's original error text; assertion checked for `err:find("intentional load failure")` which did not match. Not verified by formal Output record. |

**Fixes applied after the first run:**
- T-stage1-01: Environment configuration issue — no code change. User must publish the blank
  test place and enable "Enable Studio Access to Game Services API" in Game Settings → Security.
- T-guid-B: Code fix applied to `Stage1TestRunner.lua` (2026-11-26) — assertion B changed
  from checking specific fixture error text to `type(err) == "string" and #err > 0`.

**Current Stage 1 validation status: NOT FULLY VALIDATED.** No clean passing run has been
captured. `test-results.md` does not yet contain any formally recorded runtime output.

---

## 4. Test Limitations

- All scenario analyses in `test-results.md` are **design-level only**. Every PASS/FAIL
  annotation reflects expected behavior — not observed runtime behavior.
- `RP-T-11` Part 1 source fragments are expected to be unavailable in Studio Run/Play mode
  (`Script.Source` is `[PluginSecurity]`). The 18/18 user-reported result applies only to
  the replicated local copy, not the production function.
- Stage 1 tests validate the **current production file** (working-tree version), not the
  Revision 18 replacement. Stage 1 is a pre-implementation baseline.
- T-01 through T-18 (manual test plan) have not been executed against any implementation.

---

## 5. Outstanding Validation

| Item | Status | Required before |
|---|---|---|
| Stage 1 runtime execution — clean passing run | **Not completed** | Phase 2 implementation authorization |
| Formal recording in `test-results.md` | **Not done** | To be done after first clean run |
| Manual test plan T-01 through T-18 | **Not started** | Requires Revision 18 replacement implementation |
| All acceptance criteria | **Not runtime-verified** | Requires Revision 18 replacement implementation |

---

## 6. Known Defects and Risks

### A. Defects in b05aa20 (committed candidate — NOT APPROVED)

The committed candidate review found 5 Critical, 5 High, and 5 Medium findings.
Full details: `docs/claude-reviews/phase-1/candidate-b05aa20-review.md`.

**Critical findings (b05aa20):**

| ID | Description |
|---|---|
| B-C-01 / D-1 | Two-DataStore architecture: `TycoonSessionLocks_v1` and `TycoonPlayerData_v1` are separate keys. No cross-key atomic operation. Token-verified writes are structurally impossible. |
| B-C-02 / D-2 | Unconditional save write: callback ignores `_current`; writes regardless of session ownership. |
| B-C-03 | Lock theft silently ignored: `refreshLock` callback returns nil when another server holds the lock; no ownership-loss detection, no kick, no invalidation. Session continues writing unconditionally. |
| B-C-04 | No `_session` token in DataStore record; no per-session GUID anywhere in the file. No ownership verification at the data layer is possible. |
| B-C-05 | No lifecycle state machine; none of `playerState`, `activePlayers`, `sessionTokens`, `inFlightSaves`, `shuttingDown`, `invalidated`, or `disconnectPlayer` present in b05aa20. |

**High findings (b05aa20):**

| ID | Description |
|---|---|
| B-H-01 | No `disconnectPlayer`: no drain loop, no state guards, no final-snapshot. PlayerRemoving calls `savePlayer` directly with no ownership check. |
| B-H-02 | `savingCount` in BindToClose excludes pre-existing in-flight autosave `task.spawn` calls. BindToClose may return while autosaves are still writing. |
| B-H-03 | Post-release write window: autosave fires after `releaseLock` releases `activeLocks[userId]` but before `loadedData[userId]` is cleared. Write proceeds unconditionally after lock release. |
| B-H-04 | Double-save race: both `PlayerRemoving` and `BindToClose` call `savePlayer` and `releaseLock` independently. No `shuttingDown` guard. |
| B-H-05 | No load retries: a single transient `GetAsync` failure immediately kicks the player. `LOAD_RETRIES` not present. |

**Medium findings (b05aa20):**

| ID | File | Description |
|---|---|---|
| B-M-01 | `PlayerDataManager.lua`, `savePlayer` | Autosave writes live data reference, not a snapshot. Concurrent mutation during `withRetry` backoff can commit a partially-later state. |
| B-M-02 (SR-009) | `TycoonManager.server.lua` | Pending vault cash not flushed to `data.Cash` on disconnect; accumulated income permanently lost. Outside PlayerDataManager scope. |
| B-M-03 (SR-010) | `ShopHandler.lua` | `ProcessReceipt` not idempotent; no `PurchaseId` deduplication. Outside PlayerDataManager scope. |
| B-M-04 | `PlayerDataManager.lua:12` | Studio `JOB_ID` fallback `("studio_" .. math.floor(os.time()))` has 1-second collision window between Studio sessions. |
| B-D-03 (D-3) | `PlayerDataManager.lua`, `acquireLock` | Closure mutation + stale timestamp in `UpdateAsync` callback. |

---

### B. Revision 18 protections not yet implemented in the current working tree

The current working-tree `PlayerDataManager.lua` declares all nine state tables but does not
wire them up. The following Revision 18 requirements are absent from the current implementation:

| Revision 18 requirement | Working-tree state |
|---|---|
| `UpdateAsync`-based acquisition with fencing token | Not present; `loadPlayer` uses `GetAsync` |
| `_session` metadata in DataStore record | Not present; `savePlayer` uses `SetAsync` with no `_session` field |
| Token-verified save callback | Not present |
| `playerState` state machine used by `loadPlayer`/`savePlayer` | Tables declared; state never set or checked |
| `disconnectPlayer` function | Absent |
| Drain loop (`shuttingDown`, `inFlightSaves` accounting) | Tables declared; never used |
| `sessionTokens` populated and verified | Table declared; never written |
| `LOAD_RETRIES` retry loop | `LOAD_RETRIES = 3` declared; not applied in `loadPlayer` |

---

### C. Defects directly observable in the current working-tree source

These findings are based on direct read of the uncommitted `PlayerDataManager.lua` working-tree
file. They describe the actual state of the code, not the b05aa20 candidate.

| Observable defect | Evidence |
|---|---|
| **Failed `GetAsync` treated as new player.** `loadPlayer` falls into the `else` branch on `pcall` failure and returns `deepCopy(DEFAULT_DATA)` — the same path as a genuinely new player. Data loss on transient DataStore error. | Lines 69–87: `if success and data then ... else loadedData[userId] = deepCopy(DEFAULT_DATA) end` |
| **`savePlayer` uses `SetAsync` unconditionally.** No ownership check, no token, no fencing. Any server can overwrite any other server's data. | Lines 94–96: `PlayerStore:SetAsync(userId, data)` |
| **No coordination between `PlayerRemoving` and `BindToClose`.** Both call `savePlayer` for the same player during shutdown with no `shuttingDown` guard. | Lines 139–148 |
| **Eight lifecycle/state tables declared but never used.** `loadedData` is actively read and written by the legacy persistence code (lines 81, 83, 91, 104, 141). The other eight newly introduced tables — `playerState`, `sessionTokens`, `activeLocks`, `lastRefresh`, `inFlightSaves`, `shuttingDown`, `invalidated`, `activePlayers` — are declared but not read or written by any function. | Lines 22–30 vs. all function bodies |
| **Empty `Heartbeat` handler registered.** `RunService.Heartbeat:Connect` is called with an empty function body. No-op but registers a persistent connection. | Lines 124–126 |

**Note:** B-C-03 (`refreshLock`), B-H-02 (`savingCount`/concurrent autosave spawns), and
B-H-03 (`releaseLock`) describe mechanisms specific to the b05aa20 candidate. None of those
mechanisms exist in the current working tree (`refreshLock`, `releaseLock`, `savingCount`,
and concurrent `task.spawn` per player are absent). These b05aa20-specific defects do not
directly apply to the current working-tree source.

### In Revision 18 architecture (design reviewed — not yet implemented)

| ID | Severity | Description |
|---|---|---|
| Risk 8 | Low/accepted | In-flight `refreshSession` task can extend the TTL anchor in the abandoned path. Worst-case delay: ~20s beyond expected TTL. No minimal fix feasible. |
| Risk 9 | Low/accepted | Ghost DataStore session after F-1 path (all acquisition retries `ok=false`). Session blocked up to `LOCK_TTL`. |
| Risk 1 | Accepted | `UpdateAsync` behavior when callback returns nil is not confirmed by Roblox docs. Design handles both behaviors. |

### In replacement plan (C-3 — unresolved)

| ID | Severity | Description |
|---|---|---|
| C-3 | Blocking | §5.3 Idempotency Decision: Alt 1 (token-only, current) vs Alt 2 (compound with jobId). Decision owner: user. Stage 2 blocked until resolved. See `DECISIONS.md` and `docs/claude-reviews/phase-1/idempotency-gap-proposal.md`. |

---

## 7. Blockers Before Phase 2

1. **C-3 unresolved** — §5.3 idempotency decision (Alt 1 vs Alt 2) requires explicit written
   authorization from the user. Recorded in `DECISIONS.md`.
2. **Stage 1 runtime validation incomplete** — no clean passing run captured in `test-results.md`.
3. **Stage 1 implementation not yet authorized** — plan is reviewed with conditions but no
   explicit implementation authorization has been given.
4. **Revision 18 approval conflict** — formal approval status requires user confirmation
   (see §1 above).

---

## 8. Exact Next Recommended Task

**Immediate:** Complete Stage 1 runtime validation.

Steps:
1. Publish the blank test Roblox place as a private experience.
2. Enable "Enable Studio Access to Game Services API" in that place's Game Settings → Security.
3. Place `PlayerDataManager` (from `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua`,
   working-tree version) into ServerStorage in the blank place.
4. Place `Stage1TestRunner.lua` into ServerScriptService.
5. Create `_Stage1Test_ErrorModule` in ServerStorage with body:
   `error("_Stage1Test_ErrorModule: intentional load failure")` followed by `return {}`.
6. Click Run. Capture the full Output log verbatim.
7. Provide the Output to Claude Code to record formally in `test-results.md`.

**After Stage 1 passes:** Resolve C-3, confirm Revision 18 approval, then authorize Stage 1
implementation with the Revision 18 replacement design.
