# AI Collaboration Handoff — Cash Empire Tycoon

**Project:** Cash Empire Tycoon (Roblox game)
**Repository branch:** `feature/ai-collaboration-workflow`
**HEAD at document creation:** `940520c2913c92849fad50de769b669a181b32b5`
**Working tree state:** Contains staged, unstaged, and untracked changes (see §7).
**GitHub is the shared source of truth.**
**Last updated:** 2026-11-26

---

## 1. Project Purpose and Architecture Context

Cash Empire Tycoon is a Roblox game whose server-side data layer is implemented in
`RobloxTycoon/src/ServerScripts/PlayerDataManager.lua`.

The current work is a Phase 1 review and replacement design for that module. The existing
candidate commit (`b05aa20`) was not approved due to a two-DataStore architecture (D-1) that
makes token-verified writes structurally impossible. Revision 18 design reviewed; formal user
approval status requires confirmation (see §1 of CURRENT_STATUS.md). The design replaces
b05aa20 with a single-key fencing design that embeds `_session` metadata inside
`TycoonPlayerData_v1[tostring(userId)]`.

All architecture decisions, defect records, and test scenario analyses are in:

```
docs/claude-reviews/phase-1/
  architecture.md              — Revision 18 session locking design (review status: see CURRENT_STATUS §1)
  implementation-report.md     — Defect history D-1 through D-24, all requirements R1–R30
  test-results.md              — Design-level test scenario analyses (no runtime validation yet)
  replacement-implementation-plan.md — Staged implementation plan
  replacement-plan-review.md   — Independent review (APPROVE WITH CONDITIONS)
  candidate-b05aa20-review.md  — Source review of the rejected candidate; full risk register
  idempotency-gap-proposal.md  — §5.3 idempotency gap analysis (C-3 unresolved; Alt 1/2/3)
  source-review.md             — Original source-level review
```

The production source is at:

```
RobloxTycoon/src/ServerScripts/PlayerDataManager.lua
```

Stage 1 test harness (blank-place Studio execution only):

```
RobloxTycoon/_stage1_tests/Stage1TestRunner.lua
RobloxTycoon/_stage1_tests/T-stage1-01-module-init.lua
RobloxTycoon/_stage1_tests/RP-T-11-deepCopy.lua
RobloxTycoon/_stage1_tests/T-guid-failure-isolated.lua
```

---

## 2. Collaboration Roles and Responsibilities

| Agent | Role | Access | May implement? |
|---|---|---|---|
| **Claude Code** | Primary implementation agent | Full repository read/write | Yes — when explicitly assigned by the user |
| **Codex** | Independent code reviewer | Full repository read/write | Yes — when explicitly assigned by the user |
| **ChatGPT** | Architecture reviewer, adversarial reviewer, technical advisor, cross-reviewer | Read-only GitHub access | No — read-only unless explicitly assigned |
| **User** | Project owner | Full authority | Approves all scope, risky changes, commits, pushes, merges, deployments |

**Rule:** An agent assigned to review a deliverable is not simultaneously authorized to
implement it. Review and implementation assignments must be explicit and separate.

---

## 3. How Work Is Handed Off

**Channel:** GitHub is the sole shared source of truth. All work products (architecture
revisions, test analyses, implementation plans, findings) are committed to the repository
before handoff to another agent.

**Handoff procedure:**
1. The completing agent pushes its deliverable to the branch (or notifies the user to push
   it, depending on what the user has authorized).
2. The receiving agent reads the current HEAD of the relevant files before beginning work.
3. An agent must not begin work on a deliverable until the prior agent's output is committed
   and readable.

**ChatGPT handoff specifically:** ChatGPT has read-only GitHub access. To hand off to
ChatGPT:
- The user shares the GitHub URL for the specific file or commit.
- ChatGPT reads the committed content and responds with findings or questions.
- ChatGPT's findings are communicated back via the user (ChatGPT cannot push directly).
- Claude Code or Codex incorporates approved findings on explicit user instruction.

---

## 4. Required Evidence for Implementation and Test Claims

**Implementation claim:** An implementation is complete only when:
- The code matches the accepted architecture specification exactly.
- All requirements R1–R30 are traceable to specific code lines.
- An independent code review (by a different agent) has been completed and all blocking
  findings are resolved.
- The user has given explicit authorization to commit.

**Test claim:** A test result is valid only when:
- The test was executed in a Roblox Studio blank-place environment (not the live Cash Empire
  Tycoon experience).
- The actual Studio Output log is captured and recorded verbatim in `test-results.md`.
- Each assertion is marked as PASS or FAIL based on observed output, not design expectation.

**Prohibition:** No agent may mark a test as PASS, record a test result as verified, or claim
runtime validation without actual captured Studio Output recorded in `test-results.md`. The
current `test-results.md` contains design-level analysis only and must not be described as
containing runtime-validated results.

---

## 5. Review and Approval Process

**Architecture change:**
1. Claude Code or Codex proposes the change in a new document or as an architecture revision.
2. ChatGPT (or a separate agent) performs an adversarial review.
3. All CRITICAL/HIGH findings must be resolved before the user approves the revision.
4. User gives explicit written authorization before `architecture.md` is updated.

**Implementation:**
1. User explicitly assigns an agent to implement a specific stage.
2. The agent implements against the accepted architecture revision.
3. A different agent performs independent code review against the architecture.
4. All blocking findings resolved before the user authorizes commit.

**Test results:**
1. User runs tests in Roblox Studio blank-place environment.
2. Actual Output is provided to Claude Code.
3. Claude Code records the results verbatim in `test-results.md`.
4. No claim of validation is made until all relevant assertions PASS.

---

## 6. Rules Preventing Agents from Overwriting Each Other's Work

1. An agent must read the current committed version of any file before writing to it.
2. An agent must not modify a file that another agent is currently assigned to review.
3. During the review phase: Claude Code may only create files inside
   `docs/claude-reviews/phase-1/` or `RobloxTycoon/_stage1_tests/`. It may not modify
   production source, `README.md`, or existing documentation.
4. No agent may amend or force-push a commit that records another agent's reviewed deliverable.
5. If two agents produce conflicting findings on the same section, both findings are recorded
   and the conflict is explicitly flagged for the user to resolve — not silently merged.

---

## 7. Git, Uncommitted Work, and Handoff Protocol

### Current repository state

**Branch:** `feature/ai-collaboration-workflow`
**HEAD:** `940520c2913c92849fad50de769b669a181b32b5`
**Working tree:** Contains staged, unstaged, and untracked changes. These include:

- `RobloxTycoon/src/ServerScripts/PlayerDataManager.lua` — unstaged modifications (partial
  Stage 1 migration: single DataStore handle, GUID JOB_ID fallback, 9 state tables declared;
  `loadPlayer`/`savePlayer` still use legacy `GetAsync`/`SetAsync` behavior).
- `docs/claude-reviews/phase-1/architecture.md`, `implementation-report.md`,
  `test-results.md` — staged and unstaged modifications (review documentation).
- Multiple untracked files in `docs/claude-reviews/phase-1/` and
  `RobloxTycoon/_stage1_tests/` — created during the review phase but not yet committed.
- `README.md` — untracked.

### Handling uncommitted artifacts

**An uncommitted file is not an approved deliverable.** The following rules apply:

1. **No agent may treat uncommitted changes as authorized for deployment or as a basis for
   dependent work** (e.g., building Stage 2 on top of an uncommitted Stage 1 partial).
2. **Before proposing changes to any file, an agent must check whether that file has
   uncommitted modifications.** Reading only the committed version while uncommitted changes
   exist in the working tree may produce incorrect analysis.
3. **Uncommitted changes must not be overwritten without the user's explicit instruction.**
   If an agent identifies a conflict between committed and uncommitted content, it must report
   the conflict to the user and wait for instruction.
4. **All commits, pushes, and merges require explicit user authorization** for each specific
   action. A prior authorization to commit one file does not authorize committing others.

### Git and deployment authorization table

| Action | Who may authorize | Who may execute |
|---|---|---|
| `git add` / `git commit` | User only | User (or agent explicitly directed by user for that action) |
| `git push` | User only | User (or agent explicitly directed by user for that action) |
| `git merge` | User only | User only |
| `git reset`, `git restore`, `git stash`, `git clean` | User only (destructive) | User only |
| Deploy to live Roblox experience | User only | User only |
| Run tests in live experience | Never authorized | Never executed |
| Run tests in blank Studio place | User only | User (agent provides setup instructions) |
| Create new files in `_stage1_tests/` or `docs/claude-reviews/phase-1/` | User authorization implied for review phase | Claude Code (review phase only) |
| Modify production Lua source | Explicit user authorization required per change | Assigned implementation agent only |

**Absolute prohibitions (all agents, all circumstances):**
- Never run any test against the live Cash Empire Tycoon experience or its DataStores.
- Never stage, commit, push, merge, reset, stash, restore, or clean without explicit user
  instruction for that specific action.
- Never start Phase 2 implementation.
- Never modify `README.md` or existing documentation without explicit user authorization.
- Never treat uncommitted work as automatically approved or safe to overwrite.
