# PROJECT_STATE.md — Cash Empire Tycoon

**Last verified:** 2026-11-26
**Verified by:** Claude Sonnet 4.6 (read-only assessment, this session)

Fields marked `[UNVERIFIED — historical]` have not been confirmed in the current
repository state and may be stale.

---

## Game

**Name:** Cash Empire Tycoon
**Repository root:** `c:\Users\abdulaziz.a\Desktop\AAA\Umar\` (local)
**Rojo sync root:** `RobloxTycoon/src/` → Studio via `default.project.json`

---

## Current Branch and HEAD

**Active branch:** `feature/ai-collaboration-workflow`
**HEAD commit:** `e15582b` — "test: verify handoff notification automation"

This branch was created for CI workflow automation (handoff notifications),
not for game implementation. It is not the implementation branch.

---

## Implementation Branch

**Branch:** `feature/phase-1-data-foundation`
**Implementation commit:** `b05aa20` — "feat(phase-1): safe data persistence — session locking, load guard, UpdateAsync"
**Baseline commit:** `22a5bb9` — "Initial commit — Cash Empire Tycoon Roblox project"

> `[UNVERIFIED — historical]` These commits exist in the local repository and were
> confirmed present in this session. The branch has not been checked out; its current
> tip has been read via `git show`. Treat branch names and SHAs as verified for this session.

---

## Working Tree Status (as of 2026-11-26)

**Unstaged modifications (not committed):**

| File | Description |
|------|-------------|
| `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` | Stage 1 preamble applied: `HttpService` added, 9 state tables declared, full constants block, single `PlayerStore` (no `LockStore`), `JOB_ID` uses `GenerateGUID`. Underlying load/save functions are still pre-Stage-2. |
| `docs/claude-reviews/phase-1/architecture.md` | Modified (Revision 18 amendments) |
| `docs/claude-reviews/phase-1/implementation-report.md` | Modified |
| `docs/claude-reviews/phase-1/test-results.md` | Modified (Revision 18, 1974 lines) |

**Untracked files/directories (not committed, not ignored):**

- `.claude/`
- `CLAUDE.md`
- `README.md`
- `RobloxTycoon/_stage1_tests/` (4 test scripts)
- `docs/claude-reviews/phase-1/candidate-b05aa20-review.md`
- `docs/claude-reviews/phase-1/idempotency-gap-proposal.md`
- `docs/claude-reviews/phase-1/replacement-implementation-plan.md`
- `docs/claude-reviews/phase-1/replacement-plan-review.md`
- `docs/claude-reviews/phase-1/source-review.md`

---

## Development Focus

**Current phase:** Phase 1 — Data Foundation
**Sub-phase:** Stage 1 complete (preamble applied, unstaged); Stage 2 not started

---

## Main Persistence Module

**File:** `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua`
**Architecture:** Custom single-key `UpdateAsync` session-ownership design
(Revision 18 of `docs/claude-reviews/phase-1/architecture.md`)

The Revision 18 architecture embeds `_session` metadata inside a single
`TycoonPlayerData_v1` DataStore key per player. All lock acquisition, save,
refresh, and release operations are single `UpdateAsync` calls on that key.
No separate lock DataStore exists in the target design.

---

## Implementation Plan Status

**Plan document:** `docs/claude-reviews/phase-1/replacement-implementation-plan.md`
**Plan review:** `docs/claude-reviews/phase-1/replacement-plan-review.md`
**Review verdict:** APPROVE WITH CONDITIONS

| Stage | Description | Status |
|-------|-------------|--------|
| Stage 1 | Constants + 9 state tables + single DataStore | Implemented (unstaged, not committed) |
| Stage 2 | `loadPlayer` with `UpdateAsync` acquisition, session token, D-22 guard | **Not implemented** |
| Stage 3 | `savePlayer` with snapshot + ownership-verified callback + `inFlightSaves` | **Not implemented** |
| Stage 4 | `refreshSession` loop with dual identity check | **Not implemented** |
| Stage 5 | `disconnectPlayer` lifecycle (drain, shuttingDown, D-23/D-24 guards) | **Not implemented** |
| Stage 6 | `BindToClose` two-phase wait protocol | **Not implemented** |
| Stages 7–8 | Integration regression + full Studio test suite | **Not started** |

---

## Open Architecture Decision (Blocking Stage 2)

**C-3:** Whether the acquisition callback `ourRetry` check requires
`sess.token == token` only (Alt 1) or `sess.token == token AND sess.jobId == JOB_ID`
(Alt 2). Documented in `docs/claude-reviews/phase-1/idempotency-gap-proposal.md`.
Must be resolved in writing before Stage 2 is implemented.

---

## Runtime Validation Status

**No runtime tests have been executed.**

All scenario analyses in `test-results.md` are design-level (DESIGN: PASS).
The following test scripts exist and are ready to run, but have not been executed:

| Script | Covers | Method |
|--------|--------|--------|
| `RobloxTycoon/_stage1_tests/T-stage1-01-module-init.lua` | Stage 1 module structure, 9 state tables, GenerateGUID | Blank isolated Studio place (Method A only) |
| `RobloxTycoon/_stage1_tests/RP-T-11-deepCopy.lua` | `deepCopy` function correctness | Blank isolated Studio place |
| `RobloxTycoon/_stage1_tests/T-guid-failure-isolated.lua` | GenerateGUID failure path | Blank isolated Studio place |
| `RobloxTycoon/_stage1_tests/Stage1TestRunner.lua` | Stage 1 test runner | Blank isolated Studio place |

**T-stage1-01 expects:** 15/15 automated checks pass + 6-item manual inspection checklist.
Stage 1 is not fully complete until T-stage1-01 passes in Studio.

---

## b05aa20 Candidate Review Summary

The `b05aa20` candidate was reviewed and **not approved** (review: `candidate-b05aa20-review.md`).

**Root cause:** Two-DataStore design (`TycoonPlayerData_v1` + `TycoonSessionLocks_v1`).
No cross-key atomic operations in Roblox DataStores — token-verified saves were
structurally impossible.

**Fixed in b05aa20 (preserve in replacement):**
SR-001, SR-003, SR-004 (partial), SR-007, SR-008, SR-011, SR-012

**Still open (require Stage 2–5 implementation):**
D-1, D-2, B-C-03, B-C-04, B-C-05, B-H-01 through B-H-05, B-M-01

---

## Critical Defects in Current Working-Tree Implementation

The current working-tree `PlayerDataManager.lua` (Stage 1 preamble only) has
these open critical defects that Stage 2–5 must address:

| ID | Severity | Description |
|----|----------|-------------|
| B-C-04 | Critical | No `_session` token; `savePlayer` uses `SetAsync` with no fencing |
| B-C-05 | Critical | State tables declared but not wired to any logic |
| B-C-03 | Critical | No session-loss detection in refresh |
| B-H-04 | High | No `shuttingDown` guard; double-save race on shutdown |
| B-H-02 | High | `BindToClose` excludes pre-existing in-flight autosaves |
| B-H-05 | High | `loadPlayer` has no retry loop |
| B-M-01 | Medium | `savePlayer` passes live reference, not snapshot |
| B-M-03 | Medium | `ProcessReceipt` not idempotent (pre-existing, `ShopHandler.lua`) |
| B-M-02 | Medium | Vault cash lost on disconnect (pre-existing, `TycoonManager.server.lua`) |

---

## Next Authorized Action

**Run Stage 1 runtime validation in Roblox Studio.**

1. Confirm working-tree `PlayerDataManager.lua` matches Stage 1 spec (already done — confirmed this session).
2. Run `T-stage1-01` in a blank isolated Studio place (Method A).
3. Run `RP-T-11` in the same place.
4. On test pass: commit Stage 1 preamble to `feature/phase-1-data-foundation` (requires explicit user authorization before commit).
5. Record C-3 architecture decision in writing before any Stage 2 work begins.

---

*This document must be updated after each verified implementation step.
Mark fields `[UNVERIFIED]` when they have not been confirmed in the current session.*
