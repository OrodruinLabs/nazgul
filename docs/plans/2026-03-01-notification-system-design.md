# Hydra Notification System — Design Document

**Date:** 2026-03-01
**Status:** Approved
**Supersedes:** features/NotificationSpec.md (original C#/.NET spec)

---

## Decision Summary

Build an event-driven notification system as a **TypeScript MCP server** inside the Hydra plugin repo. The server has two faces: an HTTP webhook receiver for external sources and MCP tools for Claude Code / Hydra agent integration. Events are persisted in **SQLite** for durability and queryability.

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Integration model | MCP server (Approach C) | Native Claude Code tool integration, real-time capable |
| Runtime | TypeScript / Node | Official MCP SDK, largest ecosystem |
| Location | `mcp-server/` in this repo | Ships with the plugin, single install |
| Storage | SQLite | Durable, queryable, zero-infrastructure, embedded |
| Polling cost | ETag-based conditional requests | Near-zero cost when nothing changed |

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│              EXTERNAL EVENT SOURCES                    │
│  GitHub Webhooks · CI/CD · Slack · Cron · Custom      │
└─────────────────────┬────────────────────────────────┘
                      │ HTTP POST
                      ▼
┌──────────────────────────────────────────────────────┐
│          HYDRA NOTIFICATION MCP SERVER                 │
│  TypeScript · HTTP server for webhooks                │
│  SQLite for event persistence                         │
│  MCP tools for Claude Code integration                │
│                                                       │
│  Webhook Receiver ──→ Normalizer ──→ SQLite           │
│                                          │            │
│  MCP Tools:                              │            │
│    get_pending_events  ←─────────────────┘            │
│    acknowledge_event                                  │
│    complete_event                                     │
│    emit_event                                         │
│    get_event                                          │
│    get_event_history                                  │
└──────────────────────────────────────────────────────┘
                      │ MCP tool calls
                      ▼
┌──────────────────────────────────────────────────────┐
│              HYDRA PLUGIN (existing)                   │
│  Event Router (shell) reads events via MCP tools      │
│  Routes to agents based on event type                 │
│  Agents process → produce actions                     │
│  Actions executed via gh/az/slack CLIs                │
└──────────────────────────────────────────────────────┘
```

---

## SQLite Schema

```sql
CREATE TABLE events (
  id            TEXT PRIMARY KEY,          -- UUID
  source        TEXT NOT NULL,             -- "github", "slack", "ci", "cron"
  event_type    TEXT NOT NULL,             -- "pr.opened", "build.failed", etc.
  priority      TEXT DEFAULT 'normal',     -- "critical", "high", "normal", "low"
  status        TEXT DEFAULT 'pending',    -- "pending", "processing", "done", "failed"
  project_id    TEXT,                      -- Hydra project reference
  payload       TEXT NOT NULL,             -- Raw event JSON
  metadata      TEXT,                      -- Extra context JSON
  created_at    INTEGER NOT NULL,          -- Unix timestamp (ms)
  processed_at  INTEGER,
  completed_at  INTEGER,
  retry_count   INTEGER DEFAULT 0
);

CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_source_type ON events(source, event_type);
CREATE INDEX idx_events_priority ON events(priority);

CREATE TABLE poll_state (
  resource_key  TEXT PRIMARY KEY,          -- "github:owner/repo:pr:42:comments"
  etag          TEXT,                      -- GitHub ETag for conditional requests
  last_data     TEXT,                      -- Last response JSON (for diffing)
  last_polled   INTEGER NOT NULL,
  poll_count    INTEGER DEFAULT 0
);
```

**Status flow:** `pending` → `processing` → `done` | `failed`

**Deduplication:** Composite key of `source + external_id` checked on insert. Duplicate webhooks silently dropped.

---

## MCP Tools

| Tool | Purpose |
|------|---------|
| `get_pending_events` | Fetch events by status, source, type, priority |
| `acknowledge_event` | Mark event as `processing` (agent claimed it) |
| `complete_event` | Mark as `done` or `failed` with optional result summary |
| `get_event` | Fetch single event by ID with full payload |
| `get_event_history` | Query past events with filters (date range, source, type) |
| `emit_event` | Create a new event internally — enables agent-to-agent chaining |

---

## Webhook Endpoints

```
POST /webhooks/github     → GitHub HMAC signature verification → normalize → insert
POST /webhooks/slack      → Slack signing secret verification  → normalize → insert
POST /webhooks/ci         → Token auth                         → normalize → insert
POST /webhooks/custom     → API key auth                       → normalize → insert
```

### Source Normalizers

Each source maps raw webhook payloads to the HydraEvent schema:

| GitHub Webhook | HydraEvent `event_type` |
|---|---|
| `pull_request.opened` | `pr.opened` |
| `pull_request.synchronize` | `pr.updated` |
| `pull_request_review` | `pr.review_submitted` |
| `pull_request_review_comment` | `pr.comment.created` |
| `pull_request_review_thread` (unresolved) | `pr.comment.unresolved` |
| `check_run.completed` (failure) | `build.failed` |
| `check_run.completed` (success) | `build.succeeded` |
| `push` | `push` |

---

## PR Unresolved Comment Tracking

Two complementary strategies:

### Webhook-Driven (Real-Time)

GitHub sends `pull_request_review_thread` events with `unresolved` action. The normalizer captures these as `pr.comment.unresolved` events.

### ETag-Based Polling Sweep (Catch-All)

The MCP server periodically calls the GitHub API to scan for all unresolved threads:

1. First call returns response + `ETag` header
2. Server stores ETag in `poll_state` table
3. Next poll sends `If-None-Match: {etag}`
4. **304 Not Modified** → zero body, zero tokens, zero agent invocation
5. **200 OK** → diff against `last_data`, emit events only for newly unresolved comments

Polling happens at the HTTP layer in the MCP server. **Agents are never invoked unless something actually changed.**

### Unresolved Comment Event Payload

```json
{
  "source": "github",
  "event_type": "pr.comment.unresolved",
  "priority": "high",
  "payload": {
    "pr_number": 42,
    "repo": "owner/repo",
    "thread_id": "RT_123",
    "comment_body": "This error handling doesn't cover the timeout case",
    "comment_author": "reviewer-name",
    "file_path": "src/api/handler.ts",
    "line_range": { "start": 45, "end": 52 },
    "created_at": 1709312400000
  },
  "metadata": {
    "total_unresolved": 3,
    "review_id": "PRR_456"
  }
}
```

---

## Event Router (Plugin Side)

Shell-based router with declarative JSON config at `hydra/notification-routes.json`:

```json
{
  "routes": [
    {
      "match": { "source": "github", "event_type": "pr.*" },
      "agents": ["review-gate", "qa-reviewer"]
    },
    {
      "match": { "source": "github", "event_type": "pr.comment.unresolved" },
      "agents": ["implementer"],
      "priority_override": "high"
    },
    {
      "match": { "source": "github", "event_type": "pr.comments.unresolved_summary" },
      "agents": ["review-gate", "implementer"],
      "priority_override": "high"
    },
    {
      "match": { "source": "ci", "event_type": "build.failed" },
      "agents": ["devops", "cicd"],
      "priority_override": "critical"
    },
    {
      "match": { "source": "ci", "event_type": "test.failed" },
      "agents": ["qa-reviewer"],
      "priority_override": "high"
    },
    {
      "match": { "source": "*", "event_type": "deployment.*" },
      "agents": ["devops", "observability"]
    }
  ],
  "fallback_agent": "discovery",
  "max_concurrent_events": 3
}
```

### Routing Flow

1. Call `get_pending_events` MCP tool
2. Match each event against routes (glob patterns on source + event_type)
3. Call `acknowledge_event` to claim it
4. Spawn matched agent(s) with event payload as context
5. Agent processes and produces actions
6. Execute actions via CLI tools
7. Call `complete_event` with result

### Event Chaining

Agents call `emit_event` during processing → new event enters SQLite queue → picked up on next routing pass:

```
build.failed → DevOps agent → diagnoses → emits "diagnosis.ready"
diagnosis.ready → QA agent → writes test → emits "test.created"
test.created → CI/CD agent → triggers pipeline
```

**No match = fallback:** Unmatched events go to `fallback_agent` (Discovery) for classification.

---

## Action Execution

| Action | CLI | Auto-Execute |
|---|---|---|
| `post_pr_comment` | `gh pr comment` / `gh api` | Yes |
| `resolve_thread` | `gh api` | Yes |
| `emit_event` | MCP tool | Yes |
| `create_issue` | `gh issue create` | No — requires confirmation |
| `trigger_pipeline` | `gh workflow run` | No — requires confirmation |
| `update_file` | `git add && git commit && git push` | No — requires confirmation |
| `send_slack` | Slack webhook URL | No — requires confirmation |

### Action Format

```json
{
  "event_id": "uuid-of-triggering-event",
  "actions": [
    {
      "type": "post_pr_comment",
      "params": {
        "repo": "owner/repo",
        "pr_number": 42,
        "thread_id": "RT_123",
        "body": "Addressed — added timeout handling in commit abc123"
      }
    }
  ]
}
```

### Safety Rails

- **Auto-execute whitelist** configurable per-project in `hydra/config.json`
- Destructive/visible actions require user confirmation outside AFK mode
- All actions logged for audit

---

## Integration with Hydra Loop

### Mode 1: Loop-Integrated

Event router runs as a step within Hydra's iteration cycle:

```
Iteration start
  → Check for pending events (MCP call)
  → If events: route and process before continuing normal loop
  → Continue with current task work
  → Iteration end (checkpoint, stop hook)
```

Critical-priority events can preempt current task by emitting a `BLOCKED` signal.

### Mode 2: Standalone

A `/hydra-notify` skill independent of the loop:

```
/hydra-notify              -- process all pending events
/hydra-notify --watch      -- continuous mode, poll every N seconds
/hydra-notify --source gh  -- process only GitHub events
```

### State Machine Compliance

Events do not bypass the state machine:
- Event references existing task → agent works within that task's state
- Event creates new work → planner creates new task in `PLANNED` state, normal flow follows

### Config

```json
{
  "notifications": {
    "enabled": true,
    "mcp_server": "hydra-notifications",
    "poll_interval_seconds": 30,
    "routing_config": "hydra/notification-routes.json",
    "mode": "loop-integrated",
    "auto_execute": ["post_pr_comment", "emit_event", "resolve_thread"]
  }
}
```

---

## MCP Server Project Layout

```
mcp-server/
  package.json
  tsconfig.json
  src/
    index.ts              -- MCP server entrypoint
    server.ts             -- HTTP webhook server
    db.ts                 -- SQLite connection & queries
    schema.sql            -- Table definitions
    tools/                -- MCP tool handlers
      get-pending-events.ts
      acknowledge-event.ts
      complete-event.ts
      emit-event.ts
      get-event-history.ts
      get-event.ts
    normalizers/          -- Webhook → HydraEvent mappers
      github.ts
      slack.ts
      ci.ts
      custom.ts
    auth/                 -- Webhook signature verification
      github.ts
      slack.ts
      token.ts
    polling/              -- ETag-based sweep
      poll-manager.ts
      github-comments.ts
```
