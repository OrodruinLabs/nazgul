# Design: Teammate Teardown Enforcement + Orphaned-Team Sweep

**Date:** 2026-07-24
**Status:** Draft — pending user review
**Problem owner:** next objective slot (FEAT-018; id assigned when the planner runs)

## 1. Problem

Nazgul-dispatched Agent Teams teammates accumulate idle instead of being shut
down. Observed live in session `94d0ed8b` (this repo): five idle teammates
(`r3-architect-TASK-009`, `r3-code-TASK-009`, `r3-security-TASK-009`,
`impl2-FEAT-017-TASK-010`, `rv-code-TASK-011`) whose reports were all
delivered and consumed, plus four dead-session orphan team dirs in
`~/.claude/teams/` from other projects.

Two distinct failure modes:

1. **In-session accumulation (primary).** After the orchestrator consumes a
   teammate's report, nothing shuts the teammate down. Each review round
   spawns *fresh* teammates while prior rounds' teammates idle forever.
   The cleanup steps in `agents/team-orchestrator.md` (steps 9/11) are
   prompt-level only — no mechanical guard verifies them — and the stop-hook
   teammate-dispatch prompt (`scripts/stop-hook.sh:1240`) never mentions
   teardown at all. Same failure class as every pre-FEAT-001 prompt rule:
   unenforced prose does not converge.
2. **Post-crash orphans (secondary).** A session that dies without a normal
   exit leaves `~/.claude/teams/<name>/` + `~/.claude/tasks/<name>/` on disk
   forever. No native reaper exists (open upstream issue #44917).

## 2. Verified platform constraints (CLI 2.1.218, docs + changelog research 2026-07-24)

These bound the design; they are recorded in the
`reference_claude_code_platform_facts` memory:

- `TeamCreate`/`TeamDelete` were **removed in v2.1.178**. Teams need no setup
  step; the team config dir is auto-removed on **normal** session exit.
- The only teardown primitive is per-teammate: lead sends a
  `shutdown_request` via `SendMessage`; the teammate **approves or rejects**.
  Teammates never self-terminate; idle is their terminal state otherwise.
- Hooks cannot shut teammates down. `TeammateIdle` can only allow/block the
  idle transition. There is no teammate-shutdown or team-delete hook event.
  ⇒ Enforcement must be the proven Nazgul gate shape:
  **detect (script) → direct the lead (injected prompt) → verify next
  iteration (script) → escalate (bounded, fail-open)**.
- Manual deletion of `~/.claude/teams/<name>/` + `~/.claude/tasks/<name>/` is
  the accepted workaround for orphans, safe **only when the lead session is
  provably dead** (upstream #31788 workaround).
- **UNCONFIRMED (spike required):** whether an approved shutdown removes the
  member from the team's `config.json` `members[]`. This decides the gate's
  verification signal (§4.3).

## 3. Component A — Dispatch-manifest attribution (`team` field)

The Report Contract dispatch manifest (`nazgul/dispatch/<session-name>.json`,
`templates/skill-partials/report-contract.md`) gains one field written at
spawn time:

```json
{ "teammate": "...", "report_path": "...", "feat_id": "...",
  "team": "<team-name-or-empty>", ... }
```

- Dispatchers that know their team name record it. When teammates are spawned
  into the session's implicit team (the observed norm — `session-<first 8 of
  session_id>`), the field may be empty; detection then falls back to the
  implicit-team name derived from the stop-hook payload's `session_id`.
- Backward compatible: absent field ⇒ fallback path. No migration needed for
  manifests (they are transient runtime files).

## 4. Component B — Live teardown gate (stop-hook)

New shared lib `scripts/lib/team-teardown.sh`, sourced by `stop-hook.sh`.

### 4.1 Detection: `detect_undismissed_teammates()`

At the top of each stop-hook iteration (alongside the bash-write
reconciliation pass):

1. For each `nazgul/dispatch/*.json` whose `feat_id` matches the current
   objective:
   - Resolve the team dir: manifest `team` field if non-empty, else
     `~/.claude/teams/session-<first 8 hex of session_id>/`.
   - Reuse the TeammateIdle guard's delivered check (report file exists,
     non-empty, mtime ≥ `spawned_at_epoch`).
   - **Leaked** ⇔ report delivered AND the teammate name still appears in the
     team `config.json` `members[]`.
2. Emits the leaked list as `name<TAB>report_path<TAB>team` lines; callers
   never re-parse team configs.

Safety mirrors the TeammateIdle guard: unparseable configs, missing dirs,
absent `jq`, unsafe names (`/`, `..`) ⇒ skip that entry, fail open, log.

### 4.2 Enforcement in the stop-hook

When the leaked list is non-empty, the stop-hook prepends a mandatory
directive block to the iteration prompt, **before** the next task dispatch
section:

```
TEAM TEARDOWN (mandatory, before dispatching new work):
The following teammates have delivered their reports and must be dismissed:
  - <name> (report: <path>)
For EACH: send a SendMessage shutdown_request to <name>. After the teammate
approves, delete nazgul/dispatch/<name>.json. Do NOT glob dispatch/*.json.
If a teammate REJECTS shutdown (it believes it has pending work), leave its
manifest in place and report why in your iteration summary.
```

- A `teardown_blocks` counter (incremented in each leaked manifest, same
  pattern as the idle guard's `blocks`) bounds enforcement: after **3**
  iterations still leaked, the gate stops directing, logs an escalation line,
  and calls `raise_finding` (self-improvement channel) — never deadlocks the
  loop.
- Teardown of a *rejected* shutdown is not retried mechanically beyond the
  same 3-strike bound (a rejecting teammate claims live work; forcing it is
  wrong).

### 4.3 Verification signal (spike-dependent)

**Spike (first implementation task):** in a scratch team, send a
`shutdown_request`, have it approved, and diff
`~/.claude/teams/<name>/config.json` before/after.

- If members[] reflects shutdown ⇒ primary verification is membership
  disappearance (strong: lead cannot fake it by deleting manifests).
- If not ⇒ fallback verification is manifest deletion by the lead (weaker —
  compliance-by-attestation) **plus** a telemetry event so drift is visible.
  The spike's outcome is recorded in the lib header comment either way.

### 4.4 Config

- Kill-switch: `guards.team_teardown` (default `true`).
- Schema bump v30 → v31 in `templates/config.json` +
  `scripts/migrate-config.sh` (additive-only migration, same type-guard
  pattern as v28/v29).
- Telemetry: `team_teardown` events (`leaked_detected`, `directive_injected`,
  `verified_clean`, `escalated`) via `scripts/lib/emit-event.sh` to the
  existing event log.

## 5. Component C — Orphaned-team sweep

Same lib, `sweep_orphaned_teams()`:

1. Iterate `~/.claude/teams/*/config.json`.
2. **Attribution:** a team is *project-attributable* iff any member's `cwd`
   equals the current project dir (string match after physical-path
   normalization).
3. **Liveness (conservative, both must hold to declare dead):**
   - lead `leadSessionId` has no live entry in the session tracker
     (`scripts/lib/session-tracker.sh` locks), AND
   - the lead session transcript
     (`~/.claude/projects/<munged-cwd>/<leadSessionId>.jsonl`) is missing or
     its mtime is older than a threshold (default 24 h,
     `guards.team_sweep_min_age_hours`).
   Any ambiguity (unreadable config, no leadSessionId) ⇒ treat as alive, skip.
4. Dead + attributable ⇒ delete `~/.claude/teams/<name>/` and
   `~/.claude/tasks/<name>/`, plus any `nazgul/dispatch/*.json` naming its
   members; append one JSONL record per swept team to
   `nazgul/logs/team-sweep.jsonl`.

Call sites:

- **SessionStart** (`scripts/session-context.sh`): silent auto-sweep,
  project-attributable teams only. Kill-switch `guards.team_sweep`
  (default `true`).
- **`/nazgul:clean --teams`** (skill update): verbose sweep of
  project-attributable teams; with `--teams --all`, additionally *lists*
  foreign dead teams (other cwds) and asks per team before deleting.
  Foreign teams are never touched automatically.

## 6. Component D — Doc/template repairs (stale post-2.1.178 content)

- `agents/team-orchestrator.md`: remove team-create/team-delete framing;
  replace cleanup steps 9/11 with the shutdown_request-per-teammate sequence +
  manifest deletion; require recording the `team` field in manifests; keep the
  named-team session-naming convention (it aids attribution + FleetView).
- `templates/skill-partials/report-contract.md`: add the `team` field to the
  manifest snippet; add a "Dismissal" paragraph: *after consuming a report,
  send shutdown_request; delete the manifest after approval*.
- `scripts/stop-hook.sh:1240` dispatch prompt: append the dismissal
  obligation to the teammate-dispatch instructions.
- `RULES.md` §16-adjacent (new subsection): teardown gate + sweep semantics,
  kill-switches, escalation bound.
- `CLAUDE.md` Key Concepts: one-line mention under the parallel-dispatch
  concept.

## 7. Testing

Unit/integration (`tests/`, fixture-driven, `HOME` overridden to a temp dir):

1. `detect_undismissed_teammates`: delivered+member ⇒ leaked; delivered+gone
   ⇒ clean; undelivered ⇒ not leaked (idle guard's jurisdiction); missing
   team dir / unparseable config / unsafe names ⇒ fail-open skip; implicit
   team fallback from `session_id`; `team` field override.
2. Stop-hook gate: directive injected when leaked; absent when clean;
   3-strike escalation increments + `raise_finding` called; kill-switch off ⇒
   no-op.
3. Sweep: dead+attributable swept (both dirs + manifests + log line);
   live lead untouched; fresh transcript untouched; foreign cwd untouched;
   ambiguous config untouched; age threshold honored.
4. `/nazgul:clean --teams` path smoke test; migration test v30→v31 additive.

The spike (§4.3) is a manual step documented in the implementation task, not
a CI test.

## 8. Rollout

- One objective (FEAT-018), feature branch + PR to `main`, version bump
  v2.21.0 → v2.22.0 (plugin.json + README badge + CHANGELOG + tag + release
  per the established release protocol).
- After merge, manually run `/nazgul:clean --teams --all` once to clear the
  four existing foreign orphans (Strumtry ×3, TaxGuardian) interactively and
  verify the sweep behavior on real state.

## 9. Open questions / explicitly out of scope

- **Open:** §4.3 spike outcome decides the verification signal.
- **Out of scope:** reusing teammates across review rounds instead of
  spawning fresh ones (would reduce accumulation *and* cost; real candidate,
  but it changes review provenance semantics — separate objective).
- **Out of scope:** upstream `idle_timeout` message semantics (undocumented);
  revisit if a native teammate idle-timeout ships (watch changelog).
