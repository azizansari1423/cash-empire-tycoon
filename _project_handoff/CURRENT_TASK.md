# CURRENT_TASK.md — Cash Empire Tycoon

## Approval Status

**APPROVAL STATUS: NO TASK AUTHORIZED**

No implementation task is currently approved. Claude Code must not implement
anything until this document is updated to APPROVED by an authorized reviewer.

---

## Task Template

When a task is authorized, fill in every field below and change Approval Status
to `APPROVED` before handing off to Claude Code.

---

### Task ID

<!-- Example: PHASE1-STAGE2 -->
(none)

### Objective

<!-- One sentence: what the implementation must achieve. -->
(none)

### Background

<!-- Why this task exists. Link to architecture docs, prior reviews, or defect IDs. -->
(none)

### Approved Scope

<!-- Exact list of changes permitted. Be specific: function names, behavior changes.
     Anything not listed here is out of scope and must not be touched. -->
(none)

### Files Allowed to Change

<!-- List every file Claude Code may modify. No other files may be touched. -->
(none)

### Files Prohibited from Changing

The following files must never be modified regardless of task scope:

- All files under `RobloxTycoon/src/` (game source — server-side only via
  authorized implementation tasks; never changed as a side effect)
- `docs/claude-reviews/**` (architecture documents — read-only reference)
- `RobloxTycoon/_stage1_tests/**` (test files — read-only unless the task
  explicitly authorizes a test update)
- `_project_handoff/WORKFLOW_TEST.md`
- Git history (no amend, no force-push, no reset)

### Technical Requirements

<!-- Numbered list of exact implementation requirements.
     Reference architecture sections (e.g., §5.3), defect IDs (e.g., D-22),
     and test IDs (e.g., RP-T-02) where applicable. -->
(none)

### Acceptance Criteria

<!-- Verifiable conditions that must all be true for the task to be complete.
     Each criterion must be checkable without running the game (static) or
     with a specific Studio test (runtime). -->
(none)

### Required Tests

<!-- List every test that must pass before the task is complete.
     For each test: test ID, what it covers, pass/fail criteria.
     Never mark a test passed unless it was actually executed in Studio. -->
(none)

### Open Architecture Decisions Blocking This Task

<!-- List any decisions that must be resolved in writing before implementation begins.
     Example: C-3 — §5.3 idempotency Alt 1 vs Alt 2. -->
(none)

---

## Claude Code Operating Protocol

Before starting any implementation task:

1. Read `CURRENT_TASK.md`, `IMPLEMENTATION_REPORT.md`, and `PROJECT_STATE.md` in full.
2. Do not implement anything unless `APPROVAL STATUS` above says `APPROVED`.
3. Follow the approved scope exactly. Do not add, refactor, or extend beyond it.
4. After completing implementation, update `IMPLEMENTATION_REPORT.md` with actual results.
5. Update `PROJECT_STATE.md` with the verified post-implementation project state.
6. Never claim a test passed unless it was actually executed and the output was observed.
7. Never commit or push without explicit written authorization from the user in this session.
8. Do not overwrite previous implementation reports — append a new dated section.
9. Keep game source changes in separate commits from handoff document changes.
10. Do not execute Codex or any other automated agent autonomously.
