# Objective C — Mission Control (Fleet Dashboard + Platform Layer): Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. When executed as a Nazgul objective instead, the Nazgul planner derives task manifests from this plan; task boundaries below are the intended manifest boundaries.

**Goal:** Ship the fleet substrate — global registry, full-event-bus forwarding, a collector service owning the database (SQLite local / Postgres remote), OTel identity stamping, `/nazgul:fleet` CLI view, and doctor checks — on top of Claude Code's native Agent View, which owns session lifecycle (attach/logs/stop/respawn).

**Architecture:** Loops stay jq+git+bash and never read the DB (spec §2 projection principle): they POST events/snapshots best-effort via the existing webhook idiom. The collector is a NEW standalone app (Node.js LTS + better-sqlite3 WAL; Postgres via the same SQL through a thin adapter) living in `collector/` in this repo, versioned with the plugin but deployable separately. The web frontend is a **separate sub-project** (see Scope Note) — this plan ends at a working collector API + CLI fleet view.

**Tech Stack:** bash, jq, git, `claude agents --json` (Agent View, research preview — probed, with file fallback), Node.js LTS + better-sqlite3 (collector only), OpenTelemetry env-var stamping (no SDK).

**Binding spec:** `docs/superpowers/specs/2026-08-03-graph-domains-concurrency-mission-control-design.md` §2, §5.

## Scope Note (per writing-plans scope check)

The browser frontend (fleet page, drill-down, xterm.js terminal panel, notifications, auth) is an independent subsystem with its own stack and test story. It gets its own spec + plan when this substrate exists (brainstorm again then — Agent View's contract and the web-stack choice will both have moved by execution time). Spec §5 C3 records the approved product shape so nothing is lost. **This plan deliberately stops at: collector API serving fleet JSON + `/nazgul:fleet` CLI rendering it.** Everything the frontend needs (data, controls, terminal seam via `claude attach`) is proven by the CLI first.

## Global Constraints

- Re-ground everything before editing: Agent View is a research preview (`claude agents --json` contract may have shifted; on-disk fallbacks `~/.claude/daemon/roster.json`, `~/.claude/jobs/<id>/state.json`); FEAT-027 may have landed.
- Loops gain ZERO new runtime dependencies. Node.js is a collector-only dependency; a loop with `collector.enabled: false` (default) behaves byte-identically to today.
- All forwarding is opt-in, kill-switched, non-blocking (`--max-time 5 --connect-timeout 2`, `|| true`) — the `webhook-forward.sh` idiom exactly.
- Registry lives at `~/.nazgul/registry.json`; every writer treats it as append-and-prune JSON, `flock`-guarded, malformed file → recreate + stderr warning (never crash a loop over dashboard state).
- Degradations are announced: Agent View absent/drifted → fleet renders registry+files-only and says so; collector unreachable → forwarder drops silently by design (its `|| true` contract) but doctor reports it.
- Config keys (additive migration, next N at execution time): `collector.enabled` (default `false`), `collector.url` (default `""`), `collector.forward_events` (default `true` when enabled), `collector.snapshot_per_iteration` (default `true` when enabled), `telemetry.otel_stamp` (default `false`).
- Shell rules as repo standard; collector gets its own test setup (`collector/package.json` scripts), wired into CI as a separate job — never into `tests/run-tests.sh`'s bash harness.

---

### Task 1: Global registry — writers + prune

**Files:**
- Create: `scripts/lib/registry.sh` (sourced lib)
- Modify: `skills/init/SKILL.md` (append-on-init step), `scripts/worktree-utils.sh` (`create_feature_worktree` calls it — soft dependency shipped in Objective B; guard with `command -v registry_append`)
- Test: `tests/test-registry.sh` (new)

**Interfaces:**
- Produces: `registry_append <project_root> <worktree_path> <feat_id>` (creates `~/.nazgul/registry.json` if absent; entry `{project_root, worktree, feat_id, created_at}`; dedupes on worktree path); `registry_list` (prints entries, pruning ones whose worktree path no longer exists); `NAZGUL_REGISTRY` env override for tests.

- [ ] **Step 1: Write failing tests**: append creates file + entry; duplicate append dedupes; `registry_list` prunes a deleted path and persists the prune; malformed JSON → recreated with stderr warning, exit 0.
- [ ] **Step 2: Run** `tests/run-tests.sh --filter=registry` — FAIL.
- [ ] **Step 3: Implement** with `flock` on `~/.nazgul/.registry.lock`, jq read-modify-write to temp + `mv`.
- [ ] **Step 4: Run** filter — PASS; `shellcheck` clean.
- [ ] **Step 5: Commit**: `feat: global fleet registry (~/.nazgul/registry.json) with append/prune`

### Task 2: Config — `collector.*` + `telemetry.otel_stamp` (additive migration)

**Files:**
- Modify: `templates/config.json`, `scripts/migrate-config.sh`
- Test: `tests/test-migrate-config.sh` (extend)

**Interfaces:**
- Produces: keys per Global Constraints, readable by Tasks 3/6.

- [ ] **Step 1: Write failing migration test** (same template as every additive migration: defaults set, explicit values preserved, idempotent).
- [ ] **Step 2: Run** filter — FAIL. **Step 3: Implement** migration. **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**: `feat: collector + otel_stamp config (additive schema migration)`

### Task 3: Event/snapshot forwarder — the loop side

**Files:**
- Create: `scripts/collector-forward.sh` (fail-open observe-only script — every path falls through to `exit 0`, no `set -e`, per the in-flight-marker precedent)
- Modify: `hooks/hooks.json` (Stop + PostCompact entries alongside webhook-forward), `scripts/stop-hook.sh` (one call at iteration boundary when `collector.snapshot_per_iteration`)
- Test: `tests/test-collector-forward.sh` (new; local netcat/python-http fixture as the fake collector)

**Interfaces:**
- Consumes: `nazgul/logs/events.jsonl`, latest `nazgul/checkpoints/iteration-*.json`, `nazgul/in-flight/*.json`, config keys (Task 2).
- Produces: POSTs to `<collector.url>/ingest/events` (JSONL batch since last cursor, cursor persisted at `nazgul/.collector-cursor`) and `<collector.url>/ingest/snapshot` (body: `{registry_key, feat_id, snapshot: <checkpoint JSON>, in_flight: [...]}`). Disabled/unreachable → silent no-op, cursor unmoved.

- [ ] **Step 1: Write failing tests**: (a) enabled + fake collector → events since cursor POSTed once, cursor advances; (b) collector down → exit 0, cursor unmoved; (c) `collector.enabled: false` → no request attempted (fixture asserts zero hits); (d) malformed cursor file → resend from start, warning on stderr.
- [ ] **Step 2: Run** filter — FAIL. **Step 3: Implement** (curl, `--max-time 5 --connect-timeout 2`, `|| true`; cursor = byte offset via `wc -c`). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**: `feat: collector-forward — full event bus + iteration snapshots, fail-open`

### Task 4: Collector service — ingest + fleet API (SQLite, Postgres-ready)

**Files:**
- Create: `collector/package.json`, `collector/src/server.js`, `collector/src/db.js` (SQL adapter seam), `collector/src/schema.sql`, `collector/README.md`
- Test: `collector/test/ingest.test.js`, `collector/test/fleet.test.js` (node:test runner)
- Modify: `.github/workflows/test.yml` (separate `collector-tests` job: `cd collector && npm ci && npm test`)

**Interfaces:**
- Produces HTTP API: `POST /ingest/events` (JSONL body → `events` table), `POST /ingest/snapshot` (→ `snapshots` upsert-latest + history), `GET /fleet` (one row per registry_key: latest snapshot summary + last event + in-flight agents), `GET /loops/:key/events?since=`. Auth: `Authorization: Bearer <pre-shared key>` when `COLLECTOR_TOKEN` env set; open on localhost otherwise.
- Schema: `events(id, registry_key, ts, event, payload_json)`, `snapshots(registry_key, feat_id, iteration, ts, payload_json)`, indexes on `(registry_key, ts)`. All SQL through `db.js` (better-sqlite3 now; the adapter's contract is plain parameterized SQL so a `pg` implementation is a drop-in later — no ORM).

- [ ] **Step 1: Write failing ingest tests** (node:test + supertest-style fetch against an ephemeral server + `:memory:` DB): events batch lands with correct rows; snapshot upserts latest; bad JSON → 400 without crash; token required when env set.
- [ ] **Step 2: Run** `cd collector && npm test` — FAIL. **Step 3: Implement** server (no framework beyond `node:http` or express — pick express for routing brevity), schema, adapter. **Step 4: Run** — PASS.
- [ ] **Step 5: Write failing fleet tests**: two loops ingested → `GET /fleet` returns two rows, attention-ordered (BLOCKED/needs-input first — order key: any BLOCKED task count desc, then last event recency). **Step 6:** implement, run — PASS.
- [ ] **Step 7: CI job** added; run workflow locally if `act` available, else rely on CI.
- [ ] **Step 8: Commit**: `feat: collector service — event/snapshot ingest + fleet API (SQLite WAL, adapter-seam SQL)`

### Task 5: `/nazgul:fleet` CLI — the join, with announced degradation

**Files:**
- Create: `skills/fleet/SKILL.md`
- Create: `scripts/fleet.sh` (read-only; the skill's engine)
- Test: `tests/test-fleet.sh` (new; PATH-shim fake `claude` binary)

**Interfaces:**
- Consumes: `registry_list` (Task 1), `claude agents --json --all` (probed), per-worktree files (`config.json`, latest checkpoint, `in-flight/`), optionally `GET /fleet` when collector configured.
- Produces: table to stdout, one row per registry entry: `ATTN? | project | feat_id | wave | tasks(D/R/IP/IR/B) | session(state) | last event`, attention rows first. Degradations printed as a header line: `agent-view: unavailable (rendering from files)` / `collector: unreachable`.

- [ ] **Step 1: Write failing tests**: (a) fake `claude` returns two sessions matching two registry worktrees → joined rows with session state; (b) fake `claude` absent → rows render from files + explicit degradation header (never empty, never silent); (c) fake `claude` returns changed/unparseable JSON → same as (b) with `contract-drift` wording; (d) BLOCKED loop sorts first.
- [ ] **Step 2: Run** `tests/run-tests.sh --filter=fleet` — FAIL. **Step 3: Implement** (`jq` join on worktree path/cwd; checkpoint bucket summary via `task-utils.sh` counting). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**: `feat: /nazgul:fleet — attention-ordered fleet view joining Agent View with per-worktree state`

### Task 6: OTel identity stamping at dispatch

**Files:**
- Modify: the loop's session/dispatch environment setup point (locate where the loop composes long-running work env — `skills/start/SKILL.md` background-dispatch step and/or `scripts/session-context.sh`; confirm at execution which layer owns process env for the session)
- Test: `tests/test-otel-stamp.sh` (new; assert the composed env string)

**Interfaces:**
- Produces: when `telemetry.otel_stamp` is true, exported `OTEL_RESOURCE_ATTRIBUTES="nazgul.objective=<feat_id>,nazgul.task=<active_task>,nazgul.wave=<wave>"` + `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES=true`; existing user-set `OTEL_RESOURCE_ATTRIBUTES` values are merged (comma-append), never clobbered.

- [ ] **Step 1: Write failing test** for the env-composition helper: stamp on → attributes present; pre-existing user attributes preserved; stamp off → env untouched.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** as a small pure function in `scripts/lib/registry.sh` or new `scripts/lib/otel-stamp.sh`. **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**: `feat: OTel resource-attribute stamping (nazgul.objective/task/wave), opt-in`

### Task 7: Doctor checks + docs

**Files:**
- Modify: `scripts/doctor.sh`, `skills/doctor/SKILL.md`, `CLAUDE.md`, `README.md`
- Test: `tests/test-doctor.sh` (extend)

**Interfaces:**
- Produces three read-only checks: (1) Agent View probe — `claude agents --json` parseable? version ≥ floor? else "fleet view will degrade to files-only"; (2) collector configured but unreachable → advisory; (3) Nazgul repo backgrounded without `worktree.bgIsolation: "none"` → warn (background sessions auto-isolating into `.claude/worktrees/` fights Nazgul's worktree discipline — spec §5 C5).

- [ ] **Step 1: Write failing doctor tests** (fake `claude` shim states; unreachable collector fixture; settings fixture for bgIsolation).
- [ ] **Step 2: Run** filter — FAIL. **Step 3: Implement**; update CLAUDE.md (fleet command, collector concept, registry path) and README feature list. **Step 4: Run** filter then FULL bash suite AND `cd collector && npm test` — all PASS.
- [ ] **Step 5: Commit**: `feat: doctor — agent-view/collector/bgIsolation checks + docs sync`

### Task 8: Frontend sub-project handoff (no code)

- [ ] **Step 1:** File the frontend as its own inbox item (`nazgul/inbox/mission-control-frontend.md`, priority after this objective) citing spec §5 C3 (fleet page, drill-down, xterm.js terminal panel over WS→PTY running `claude logs -f`/`claude attach`, pause/resume via config writes, service-worker notifications, pre-shared-key auth) and requiring a fresh brainstorm+spec+plan cycle at pickup (Agent View contract will have moved).
- [ ] **Step 2: Commit**: `docs: mission-control frontend filed as follow-on sub-project`

## Self-review notes (done at plan time)

Spec coverage: §5 C1→Task 1, C2→Tasks 2-3-4, C3→Task 5 (CLI slice) + Task 8 (frontend deferred by design, recorded), C4→Task 6 (OTel) + C4's Agent-Monitor option consciously not planned (collector API is the stable seam; a third-party surface can point at it later without plugin changes), C5→Task 7. Projection principle held: no loop code reads the DB; only `collector-forward.sh` writes outward, fail-open. Type consistency: registry entry shape `{project_root, worktree, feat_id, created_at}` identical in Tasks 1/3/5; collector endpoints named identically in Tasks 3/4/5/7.
