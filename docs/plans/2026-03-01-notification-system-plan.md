# Notification System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a TypeScript MCP server that receives external webhooks, persists events in SQLite, and exposes MCP tools for Hydra agents to consume and act on events.

**Architecture:** Dual-interface MCP server — HTTP endpoints receive webhooks from GitHub/Slack/CI, normalize them into a standard HydraEvent schema, and store them in SQLite. Claude Code calls MCP tools to query, claim, and complete events. A shell-based router on the plugin side matches events to Hydra agents.

**Tech Stack:** TypeScript, `@modelcontextprotocol/sdk`, `better-sqlite3`, `express`, `zod`, `vitest`

**Design doc:** `docs/plans/2026-03-01-notification-system-design.md`

---

### Task 1: Project Scaffold

**Files:**
- Create: `mcp-server/package.json`
- Create: `mcp-server/tsconfig.json`
- Create: `mcp-server/vitest.config.ts`
- Create: `mcp-server/src/index.ts` (empty entrypoint)

**Step 1: Initialize the Node project**

```bash
cd mcp-server
npm init -y
```

**Step 2: Install dependencies**

```bash
npm install @modelcontextprotocol/sdk better-sqlite3 express zod uuid
npm install -D typescript @types/node @types/better-sqlite3 @types/express vitest
```

**Step 3: Create `mcp-server/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "declaration": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist", "**/*.test.ts"]
}
```

**Step 4: Create `mcp-server/vitest.config.ts`**

```typescript
import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
  },
});
```

**Step 5: Update `mcp-server/package.json` scripts**

Add to the generated package.json:

```json
{
  "type": "module",
  "scripts": {
    "build": "tsc",
    "test": "vitest run",
    "test:watch": "vitest",
    "start": "node dist/index.js"
  }
}
```

**Step 6: Create empty entrypoint `mcp-server/src/index.ts`**

```typescript
// Hydra Notification MCP Server — entrypoint
// Will wire up MCP server + HTTP webhook server
```

**Step 7: Verify it compiles**

```bash
cd mcp-server && npx tsc --noEmit
```
Expected: no errors.

**Step 8: Commit**

```bash
git add mcp-server/
git commit -m "feat: scaffold MCP server project with TypeScript and vitest"
```

---

### Task 2: SQLite Database Layer

**Files:**
- Create: `mcp-server/src/schema.sql`
- Create: `mcp-server/src/db.ts`
- Test: `mcp-server/src/db.test.ts`

**Step 1: Write the test**

Create `mcp-server/src/db.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { createDb, insertEvent, getEventById, getEventsByStatus, updateEventStatus } from './db.js';
import type { HydraEvent } from './db.js';

describe('db', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  it('inserts and retrieves an event by id', () => {
    const event: HydraEvent = {
      id: 'test-uuid-1',
      source: 'github',
      event_type: 'pr.opened',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: JSON.stringify({ pr_number: 42 }),
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    const result = getEventById(db, 'test-uuid-1');
    expect(result).not.toBeNull();
    expect(result!.source).toBe('github');
    expect(result!.event_type).toBe('pr.opened');
  });

  it('returns null for non-existent event', () => {
    const result = getEventById(db, 'does-not-exist');
    expect(result).toBeNull();
  });

  it('queries events by status', () => {
    const base = {
      source: 'ci',
      event_type: 'build.failed',
      priority: 'critical' as const,
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, { ...base, id: 'e1', status: 'pending' });
    insertEvent(db, { ...base, id: 'e2', status: 'pending' });
    insertEvent(db, { ...base, id: 'e3', status: 'done' });

    const pending = getEventsByStatus(db, 'pending');
    expect(pending).toHaveLength(2);
  });

  it('updates event status with timestamp', () => {
    const event: HydraEvent = {
      id: 'e-update',
      source: 'github',
      event_type: 'pr.opened',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    updateEventStatus(db, 'e-update', 'processing');
    const updated = getEventById(db, 'e-update');
    expect(updated!.status).toBe('processing');
    expect(updated!.processed_at).not.toBeNull();
  });

  it('silently skips duplicate inserts', () => {
    const event: HydraEvent = {
      id: 'dup-1',
      source: 'github',
      event_type: 'push',
      priority: 'normal',
      status: 'pending',
      project_id: null,
      payload: '{}',
      metadata: null,
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };
    insertEvent(db, event);
    insertEvent(db, event); // duplicate — should not throw
    const all = getEventsByStatus(db, 'pending');
    expect(all).toHaveLength(1);
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd mcp-server && npx vitest run src/db.test.ts
```
Expected: FAIL — `./db.js` does not exist.

**Step 3: Create `mcp-server/src/schema.sql`**

```sql
CREATE TABLE IF NOT EXISTS events (
  id            TEXT PRIMARY KEY,
  source        TEXT NOT NULL,
  event_type    TEXT NOT NULL,
  priority      TEXT DEFAULT 'normal',
  status        TEXT DEFAULT 'pending',
  project_id    TEXT,
  payload       TEXT NOT NULL,
  metadata      TEXT,
  created_at    INTEGER NOT NULL,
  processed_at  INTEGER,
  completed_at  INTEGER,
  retry_count   INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
CREATE INDEX IF NOT EXISTS idx_events_source_type ON events(source, event_type);
CREATE INDEX IF NOT EXISTS idx_events_priority ON events(priority);

CREATE TABLE IF NOT EXISTS poll_state (
  resource_key  TEXT PRIMARY KEY,
  etag          TEXT,
  last_data     TEXT,
  last_polled   INTEGER NOT NULL,
  poll_count    INTEGER DEFAULT 0
);
```

**Step 4: Implement `mcp-server/src/db.ts`**

```typescript
import Database from 'better-sqlite3';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

export interface HydraEvent {
  id: string;
  source: string;
  event_type: string;
  priority: 'critical' | 'high' | 'normal' | 'low';
  status: 'pending' | 'processing' | 'done' | 'failed';
  project_id: string | null;
  payload: string;
  metadata: string | null;
  created_at: number;
  processed_at: number | null;
  completed_at: number | null;
  retry_count: number;
}

export function createDb(path: string): Database.Database {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  const schema = readFileSync(join(__dirname, 'schema.sql'), 'utf-8');
  db.exec(schema);
  return db;
}

export function insertEvent(db: Database.Database, event: HydraEvent): void {
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO events
      (id, source, event_type, priority, status, project_id, payload, metadata, created_at, processed_at, completed_at, retry_count)
    VALUES
      (@id, @source, @event_type, @priority, @status, @project_id, @payload, @metadata, @created_at, @processed_at, @completed_at, @retry_count)
  `);
  stmt.run(event);
}

export function getEventById(db: Database.Database, id: string): HydraEvent | null {
  const stmt = db.prepare('SELECT * FROM events WHERE id = ?');
  return (stmt.get(id) as HydraEvent) ?? null;
}

export function getEventsByStatus(
  db: Database.Database,
  status: string,
  options?: { source?: string; event_type?: string; limit?: number }
): HydraEvent[] {
  let sql = 'SELECT * FROM events WHERE status = ?';
  const params: unknown[] = [status];

  if (options?.source) {
    sql += ' AND source = ?';
    params.push(options.source);
  }
  if (options?.event_type) {
    sql += ' AND event_type LIKE ?';
    params.push(options.event_type.replace('*', '%'));
  }

  sql += ` ORDER BY CASE priority WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 WHEN 'low' THEN 3 END, created_at ASC`;

  if (options?.limit) {
    sql += ' LIMIT ?';
    params.push(options.limit);
  }

  const stmt = db.prepare(sql);
  return stmt.all(...params) as HydraEvent[];
}

export function updateEventStatus(
  db: Database.Database,
  id: string,
  status: 'processing' | 'done' | 'failed'
): void {
  const now = Date.now();
  let sql: string;

  if (status === 'processing') {
    sql = 'UPDATE events SET status = ?, processed_at = ? WHERE id = ?';
  } else {
    sql = 'UPDATE events SET status = ?, completed_at = ? WHERE id = ?';
  }

  db.prepare(sql).run(status, now, id);
}
```

**Step 5: Run test to verify it passes**

```bash
cd mcp-server && npx vitest run src/db.test.ts
```
Expected: all 5 tests PASS.

**Step 6: Commit**

```bash
git add mcp-server/src/schema.sql mcp-server/src/db.ts mcp-server/src/db.test.ts
git commit -m "feat: add SQLite database layer with event CRUD operations"
```

---

### Task 3: MCP Server with Core Tools

**Files:**
- Create: `mcp-server/src/tools/get-pending-events.ts`
- Create: `mcp-server/src/tools/acknowledge-event.ts`
- Create: `mcp-server/src/tools/complete-event.ts`
- Create: `mcp-server/src/tools/emit-event.ts`
- Create: `mcp-server/src/tools/get-event.ts`
- Create: `mcp-server/src/tools/get-event-history.ts`
- Create: `mcp-server/src/tools/index.ts`
- Modify: `mcp-server/src/index.ts`
- Test: `mcp-server/src/tools/tools.test.ts`

**Step 1: Write the test**

Create `mcp-server/src/tools/tools.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import { createDb, getEventById, getEventsByStatus, type HydraEvent } from '../db.js';
import { handleGetPendingEvents } from './get-pending-events.js';
import { handleAcknowledgeEvent } from './acknowledge-event.js';
import { handleCompleteEvent } from './complete-event.js';
import { handleEmitEvent } from './emit-event.js';
import { handleGetEvent } from './get-event.js';
import { handleGetEventHistory } from './get-event-history.js';
import { insertEvent } from '../db.js';

function seedEvent(db: ReturnType<typeof createDb>, overrides: Partial<HydraEvent> = {}): HydraEvent {
  const event: HydraEvent = {
    id: overrides.id ?? 'seed-1',
    source: overrides.source ?? 'github',
    event_type: overrides.event_type ?? 'pr.opened',
    priority: overrides.priority ?? 'normal',
    status: overrides.status ?? 'pending',
    project_id: overrides.project_id ?? null,
    payload: overrides.payload ?? '{"pr_number":42}',
    metadata: overrides.metadata ?? null,
    created_at: overrides.created_at ?? Date.now(),
    processed_at: null,
    completed_at: null,
    retry_count: 0,
  };
  insertEvent(db, event);
  return event;
}

describe('MCP tool handlers', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  describe('get_pending_events', () => {
    it('returns pending events sorted by priority', () => {
      seedEvent(db, { id: 'low-1', priority: 'low' });
      seedEvent(db, { id: 'crit-1', priority: 'critical' });
      const result = handleGetPendingEvents(db, {});
      expect(result).toHaveLength(2);
      expect(result[0].id).toBe('crit-1');
    });

    it('filters by source', () => {
      seedEvent(db, { id: 'gh-1', source: 'github' });
      seedEvent(db, { id: 'ci-1', source: 'ci' });
      const result = handleGetPendingEvents(db, { source: 'github' });
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('gh-1');
    });
  });

  describe('acknowledge_event', () => {
    it('transitions event to processing', () => {
      seedEvent(db, { id: 'ack-1' });
      const result = handleAcknowledgeEvent(db, { event_id: 'ack-1' });
      expect(result.success).toBe(true);
      const updated = getEventById(db, 'ack-1');
      expect(updated!.status).toBe('processing');
    });

    it('fails for non-existent event', () => {
      const result = handleAcknowledgeEvent(db, { event_id: 'nope' });
      expect(result.success).toBe(false);
    });
  });

  describe('complete_event', () => {
    it('transitions event to done', () => {
      seedEvent(db, { id: 'comp-1', status: 'processing' });
      const result = handleCompleteEvent(db, { event_id: 'comp-1', status: 'done' });
      expect(result.success).toBe(true);
      const updated = getEventById(db, 'comp-1');
      expect(updated!.status).toBe('done');
      expect(updated!.completed_at).not.toBeNull();
    });
  });

  describe('emit_event', () => {
    it('creates a new event with pending status', () => {
      const result = handleEmitEvent(db, {
        source: 'internal',
        event_type: 'diagnosis.ready',
        priority: 'high',
        payload: '{"task":"TASK-001"}',
      });
      expect(result.event_id).toBeDefined();
      const created = getEventById(db, result.event_id);
      expect(created!.status).toBe('pending');
      expect(created!.source).toBe('internal');
    });
  });

  describe('get_event', () => {
    it('returns full event by id', () => {
      seedEvent(db, { id: 'get-1', payload: '{"data":"test"}' });
      const result = handleGetEvent(db, { event_id: 'get-1' });
      expect(result).not.toBeNull();
      expect(result!.payload).toBe('{"data":"test"}');
    });
  });

  describe('get_event_history', () => {
    it('returns events filtered by source and type', () => {
      seedEvent(db, { id: 'h-1', source: 'github', event_type: 'pr.opened', status: 'done' });
      seedEvent(db, { id: 'h-2', source: 'ci', event_type: 'build.failed', status: 'done' });
      const result = handleGetEventHistory(db, { source: 'github' });
      expect(result).toHaveLength(1);
      expect(result[0].id).toBe('h-1');
    });
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd mcp-server && npx vitest run src/tools/tools.test.ts
```
Expected: FAIL — tool handler modules do not exist.

**Step 3: Implement tool handlers**

Create each file under `mcp-server/src/tools/`:

`get-pending-events.ts`:
```typescript
import type Database from 'better-sqlite3';
import { getEventsByStatus, type HydraEvent } from '../db.js';

export interface GetPendingEventsInput {
  source?: string;
  event_type?: string;
  limit?: number;
}

export function handleGetPendingEvents(
  db: Database.Database,
  input: GetPendingEventsInput
): HydraEvent[] {
  return getEventsByStatus(db, 'pending', {
    source: input.source,
    event_type: input.event_type,
    limit: input.limit ?? 20,
  });
}
```

`acknowledge-event.ts`:
```typescript
import type Database from 'better-sqlite3';
import { getEventById, updateEventStatus } from '../db.js';

export interface AcknowledgeEventInput {
  event_id: string;
}

export function handleAcknowledgeEvent(
  db: Database.Database,
  input: AcknowledgeEventInput
): { success: boolean; error?: string } {
  const event = getEventById(db, input.event_id);
  if (!event) return { success: false, error: 'Event not found' };
  if (event.status !== 'pending') {
    return { success: false, error: `Event status is '${event.status}', expected 'pending'` };
  }
  updateEventStatus(db, input.event_id, 'processing');
  return { success: true };
}
```

`complete-event.ts`:
```typescript
import type Database from 'better-sqlite3';
import { getEventById, updateEventStatus } from '../db.js';

export interface CompleteEventInput {
  event_id: string;
  status: 'done' | 'failed';
  summary?: string;
}

export function handleCompleteEvent(
  db: Database.Database,
  input: CompleteEventInput
): { success: boolean; error?: string } {
  const event = getEventById(db, input.event_id);
  if (!event) return { success: false, error: 'Event not found' };
  updateEventStatus(db, input.event_id, input.status);
  return { success: true };
}
```

`emit-event.ts`:
```typescript
import type Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { insertEvent, type HydraEvent } from '../db.js';

export interface EmitEventInput {
  source: string;
  event_type: string;
  priority?: 'critical' | 'high' | 'normal' | 'low';
  payload: string;
  metadata?: string;
  project_id?: string;
}

export function handleEmitEvent(
  db: Database.Database,
  input: EmitEventInput
): { event_id: string } {
  const id = randomUUID();
  const event: HydraEvent = {
    id,
    source: input.source,
    event_type: input.event_type,
    priority: input.priority ?? 'normal',
    status: 'pending',
    project_id: input.project_id ?? null,
    payload: input.payload,
    metadata: input.metadata ?? null,
    created_at: Date.now(),
    processed_at: null,
    completed_at: null,
    retry_count: 0,
  };
  insertEvent(db, event);
  return { event_id: id };
}
```

`get-event.ts`:
```typescript
import type Database from 'better-sqlite3';
import { getEventById, type HydraEvent } from '../db.js';

export interface GetEventInput {
  event_id: string;
}

export function handleGetEvent(
  db: Database.Database,
  input: GetEventInput
): HydraEvent | null {
  return getEventById(db, input.event_id);
}
```

`get-event-history.ts`:
```typescript
import type Database from 'better-sqlite3';
import type { HydraEvent } from '../db.js';

export interface GetEventHistoryInput {
  source?: string;
  event_type?: string;
  since?: number;
  limit?: number;
}

export function handleGetEventHistory(
  db: Database.Database,
  input: GetEventHistoryInput
): HydraEvent[] {
  let sql = 'SELECT * FROM events WHERE 1=1';
  const params: unknown[] = [];

  if (input.source) {
    sql += ' AND source = ?';
    params.push(input.source);
  }
  if (input.event_type) {
    sql += ' AND event_type LIKE ?';
    params.push(input.event_type.replace('*', '%'));
  }
  if (input.since) {
    sql += ' AND created_at >= ?';
    params.push(input.since);
  }

  sql += ' ORDER BY created_at DESC LIMIT ?';
  params.push(input.limit ?? 50);

  return db.prepare(sql).all(...params) as HydraEvent[];
}
```

**Step 4: Run tests to verify they pass**

```bash
cd mcp-server && npx vitest run src/tools/tools.test.ts
```
Expected: all tests PASS.

**Step 5: Wire tools into MCP server**

Create `mcp-server/src/tools/index.ts`:
```typescript
export { handleGetPendingEvents } from './get-pending-events.js';
export { handleAcknowledgeEvent } from './acknowledge-event.js';
export { handleCompleteEvent } from './complete-event.js';
export { handleEmitEvent } from './emit-event.js';
export { handleGetEvent } from './get-event.js';
export { handleGetEventHistory } from './get-event-history.js';
```

Update `mcp-server/src/index.ts`:
```typescript
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { createDb } from './db.js';
import {
  handleGetPendingEvents,
  handleAcknowledgeEvent,
  handleCompleteEvent,
  handleEmitEvent,
  handleGetEvent,
  handleGetEventHistory,
} from './tools/index.js';

const DB_PATH = process.env.HYDRA_NOTIFICATIONS_DB ?? './hydra-notifications.db';
const db = createDb(DB_PATH);

const server = new McpServer({
  name: 'hydra-notifications',
  version: '1.0.0',
});

server.registerTool('get_pending_events', {
  title: 'Get Pending Events',
  description: 'Fetch pending events, optionally filtered by source and event type',
  inputSchema: z.object({
    source: z.string().optional(),
    event_type: z.string().optional(),
    limit: z.number().optional(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleGetPendingEvents(db, input)) }],
}));

server.registerTool('acknowledge_event', {
  title: 'Acknowledge Event',
  description: 'Claim an event for processing — transitions from pending to processing',
  inputSchema: z.object({
    event_id: z.string(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleAcknowledgeEvent(db, input)) }],
}));

server.registerTool('complete_event', {
  title: 'Complete Event',
  description: 'Mark an event as done or failed after processing',
  inputSchema: z.object({
    event_id: z.string(),
    status: z.enum(['done', 'failed']),
    summary: z.string().optional(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleCompleteEvent(db, input)) }],
}));

server.registerTool('emit_event', {
  title: 'Emit Event',
  description: 'Create a new event for agent-to-agent chaining',
  inputSchema: z.object({
    source: z.string(),
    event_type: z.string(),
    priority: z.enum(['critical', 'high', 'normal', 'low']).optional(),
    payload: z.string(),
    metadata: z.string().optional(),
    project_id: z.string().optional(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleEmitEvent(db, input)) }],
}));

server.registerTool('get_event', {
  title: 'Get Event',
  description: 'Fetch a single event by ID with full payload',
  inputSchema: z.object({
    event_id: z.string(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleGetEvent(db, input)) }],
}));

server.registerTool('get_event_history', {
  title: 'Get Event History',
  description: 'Query past events with filters (source, type, date range)',
  inputSchema: z.object({
    source: z.string().optional(),
    event_type: z.string().optional(),
    since: z.number().optional(),
    limit: z.number().optional(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(handleGetEventHistory(db, input)) }],
}));

const transport = new StdioServerTransport();
await server.connect(transport);
```

**Step 6: Verify it compiles**

```bash
cd mcp-server && npx tsc --noEmit
```
Expected: no errors.

**Step 7: Commit**

```bash
git add mcp-server/src/tools/ mcp-server/src/index.ts
git commit -m "feat: add MCP tools for event query, acknowledge, complete, and emit"
```

---

### Task 4: Webhook HTTP Server

**Files:**
- Create: `mcp-server/src/server.ts`
- Create: `mcp-server/src/auth/github.ts`
- Create: `mcp-server/src/auth/token.ts`
- Create: `mcp-server/src/normalizers/github.ts`
- Create: `mcp-server/src/normalizers/custom.ts`
- Test: `mcp-server/src/server.test.ts`

**Step 1: Write the test**

Create `mcp-server/src/server.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from './server.js';
import { createDb, getEventsByStatus } from './db.js';

describe('webhook server', () => {
  let app: ReturnType<typeof createApp>;
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
    app = createApp(db, { skipAuth: true });
  });

  it('POST /webhooks/custom inserts an event', async () => {
    const res = await request(app)
      .post('/webhooks/custom')
      .send({
        source: 'test',
        event_type: 'test.event',
        priority: 'normal',
        payload: { hello: 'world' },
      })
      .expect(201);

    expect(res.body.event_id).toBeDefined();
    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe('test.event');
  });

  it('POST /webhooks/github normalizes PR event', async () => {
    const res = await request(app)
      .post('/webhooks/github')
      .set('X-GitHub-Event', 'pull_request')
      .send({
        action: 'opened',
        number: 42,
        pull_request: {
          title: 'Add feature',
          user: { login: 'dev' },
          head: { ref: 'feature-branch' },
          base: { ref: 'main' },
        },
        repository: { full_name: 'owner/repo' },
      })
      .expect(201);

    expect(res.body.event_id).toBeDefined();
    const events = getEventsByStatus(db, 'pending');
    expect(events).toHaveLength(1);
    expect(events[0].event_type).toBe('pr.opened');
    expect(events[0].source).toBe('github');
  });

  it('GET /health returns ok', async () => {
    const res = await request(app).get('/health').expect(200);
    expect(res.body.status).toBe('ok');
  });

  it('rejects unknown webhook path', async () => {
    await request(app).post('/webhooks/unknown').send({}).expect(404);
  });
});
```

**Step 2: Install supertest**

```bash
cd mcp-server && npm install -D supertest @types/supertest
```

**Step 3: Run test to verify it fails**

```bash
cd mcp-server && npx vitest run src/server.test.ts
```
Expected: FAIL — `./server.js` does not exist.

**Step 4: Implement auth modules**

`mcp-server/src/auth/github.ts`:
```typescript
import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Request } from 'express';

export function verifyGitHubSignature(req: Request, secret: string): boolean {
  const signature = req.headers['x-hub-signature-256'] as string | undefined;
  if (!signature) return false;
  const body = JSON.stringify(req.body);
  const expected = 'sha256=' + createHmac('sha256', secret).update(body).digest('hex');
  try {
    return timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
  } catch {
    return false;
  }
}
```

`mcp-server/src/auth/token.ts`:
```typescript
import type { Request } from 'express';

export function verifyBearerToken(req: Request, expectedToken: string): boolean {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return false;
  return header.slice(7) === expectedToken;
}
```

**Step 5: Implement GitHub normalizer**

`mcp-server/src/normalizers/github.ts`:
```typescript
import type { Request } from 'express';
import type { HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

const EVENT_MAP: Record<string, (action: string) => string | null> = {
  pull_request: (action) => {
    if (action === 'opened') return 'pr.opened';
    if (action === 'synchronize') return 'pr.updated';
    if (action === 'closed') return 'pr.closed';
    return `pr.${action}`;
  },
  pull_request_review: () => 'pr.review_submitted',
  pull_request_review_comment: () => 'pr.comment.created',
  pull_request_review_thread: (action) => {
    if (action === 'unresolved') return 'pr.comment.unresolved';
    if (action === 'resolved') return 'pr.comment.resolved';
    return null;
  },
  check_run: () => null, // handled separately based on conclusion
  push: () => 'push',
};

type PartialHydraEvent = Omit<HydraEvent, 'status' | 'processed_at' | 'completed_at' | 'retry_count'>;

export function normalizeGitHub(req: Request): PartialHydraEvent | null {
  const githubEvent = req.headers['x-github-event'] as string;
  const body = req.body;
  const action = body.action ?? '';

  let eventType: string | null = null;

  if (githubEvent === 'check_run' && body.action === 'completed') {
    eventType = body.check_run?.conclusion === 'success'
      ? 'build.succeeded'
      : 'build.failed';
  } else {
    const mapper = EVENT_MAP[githubEvent];
    if (!mapper) return null;
    eventType = mapper(action);
  }

  if (!eventType) return null;

  const repo = body.repository?.full_name ?? 'unknown';

  return {
    id: body.delivery ?? randomUUID(),
    source: 'github',
    event_type: eventType,
    priority: eventType.includes('failed') || eventType.includes('unresolved') ? 'high' : 'normal',
    project_id: null,
    payload: JSON.stringify(body),
    metadata: JSON.stringify({ repo }),
    created_at: Date.now(),
  };
}
```

**Step 6: Implement custom normalizer**

`mcp-server/src/normalizers/custom.ts`:
```typescript
import type { Request } from 'express';
import type { HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

type PartialHydraEvent = Omit<HydraEvent, 'status' | 'processed_at' | 'completed_at' | 'retry_count'>;

export function normalizeCustom(req: Request): PartialHydraEvent | null {
  const body = req.body;
  if (!body.source || !body.event_type) return null;

  return {
    id: body.id ?? randomUUID(),
    source: body.source,
    event_type: body.event_type,
    priority: body.priority ?? 'normal',
    project_id: body.project_id ?? null,
    payload: JSON.stringify(body.payload ?? {}),
    metadata: body.metadata ? JSON.stringify(body.metadata) : null,
    created_at: Date.now(),
  };
}
```

**Step 7: Implement the Express server**

`mcp-server/src/server.ts`:
```typescript
import express, { type Request, type Response } from 'express';
import type Database from 'better-sqlite3';
import { insertEvent, type HydraEvent } from './db.js';
import { normalizeGitHub } from './normalizers/github.js';
import { normalizeCustom } from './normalizers/custom.js';
import { verifyGitHubSignature } from './auth/github.js';
import { verifyBearerToken } from './auth/token.js';

interface ServerOptions {
  skipAuth?: boolean;
  githubSecret?: string;
  apiToken?: string;
}

export function createApp(db: Database.Database, options: ServerOptions = {}) {
  const app = express();
  app.use(express.json());

  app.get('/health', (_req: Request, res: Response) => {
    res.json({ status: 'ok', timestamp: Date.now() });
  });

  app.post('/webhooks/github', (req: Request, res: Response) => {
    if (!options.skipAuth && options.githubSecret) {
      if (!verifyGitHubSignature(req, options.githubSecret)) {
        res.status(401).json({ error: 'Invalid signature' });
        return;
      }
    }

    const normalized = normalizeGitHub(req);
    if (!normalized) {
      res.status(400).json({ error: 'Unrecognized GitHub event' });
      return;
    }

    const event: HydraEvent = {
      ...normalized,
      status: 'pending',
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };

    insertEvent(db, event);
    res.status(201).json({ event_id: event.id });
  });

  app.post('/webhooks/custom', (req: Request, res: Response) => {
    if (!options.skipAuth && options.apiToken) {
      if (!verifyBearerToken(req, options.apiToken)) {
        res.status(401).json({ error: 'Invalid token' });
        return;
      }
    }

    const normalized = normalizeCustom(req);
    if (!normalized) {
      res.status(400).json({ error: 'Missing required fields: source, event_type' });
      return;
    }

    const event: HydraEvent = {
      ...normalized,
      status: 'pending',
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };

    insertEvent(db, event);
    res.status(201).json({ event_id: event.id });
  });

  return app;
}
```

**Step 8: Run tests**

```bash
cd mcp-server && npx vitest run src/server.test.ts
```
Expected: all tests PASS.

**Step 9: Commit**

```bash
git add mcp-server/src/server.ts mcp-server/src/auth/ mcp-server/src/normalizers/ mcp-server/src/server.test.ts
git commit -m "feat: add webhook HTTP server with GitHub and custom normalizers"
```

---

### Task 5: ETag-Based Polling for PR Comments

**Files:**
- Create: `mcp-server/src/polling/poll-manager.ts`
- Test: `mcp-server/src/polling/polling.test.ts`

**Step 1: Write the test**

Create `mcp-server/src/polling/polling.test.ts`:

```typescript
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createDb, getEventsByStatus } from '../db.js';
import { PollManager } from './poll-manager.js';

describe('PollManager', () => {
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
  });

  it('stores etag and sends If-None-Match on second poll', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => h === 'etag' ? '"abc123"' : null },
        json: async () => ([]),
      })
      .mockResolvedValueOnce({
        status: 304,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);
    const key = 'github:owner/repo:pr:1:comments';
    const url = 'https://api.github.com/repos/owner/repo/pulls/1/comments';

    await manager.poll(key, url);
    await manager.poll(key, url);

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const secondCall = fetchMock.mock.calls[1];
    expect(secondCall[1].headers['If-None-Match']).toBe('"abc123"');
  });

  it('returns changed=false on 304', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce({
        status: 200,
        headers: { get: (h: string) => h === 'etag' ? '"first"' : null },
        json: async () => ([]),
      })
      .mockResolvedValueOnce({
        status: 304,
        headers: { get: () => null },
      });

    const manager = new PollManager(db, fetchMock as any);
    const key = 'test:resource';
    await manager.poll(key, 'https://example.com');
    const result = await manager.poll(key, 'https://example.com');
    expect(result.changed).toBe(false);
  });

  it('emits summary event for unresolved comments', async () => {
    const comments = [
      { id: 1, body: 'Fix this', user: { login: 'reviewer' }, path: 'src/app.ts', line: 10, created_at: '2026-01-01T00:00:00Z' },
    ];
    const fetchMock = vi.fn().mockResolvedValueOnce({
      status: 200,
      headers: { get: (h: string) => h === 'etag' ? '"first"' : null },
      json: async () => comments,
    });

    const manager = new PollManager(db, fetchMock as any);
    await manager.pollGitHubUnresolvedComments('owner/repo', 1);

    const events = getEventsByStatus(db, 'pending');
    expect(events.length).toBeGreaterThanOrEqual(1);
    expect(events[0].event_type).toBe('pr.comments.unresolved_summary');
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd mcp-server && npx vitest run src/polling/polling.test.ts
```
Expected: FAIL — module doesn't exist.

**Step 3: Implement `poll-manager.ts`**

`mcp-server/src/polling/poll-manager.ts`:
```typescript
import type Database from 'better-sqlite3';
import { insertEvent, type HydraEvent } from '../db.js';
import { randomUUID } from 'node:crypto';

type FetchFn = typeof globalThis.fetch;

interface PollState {
  resource_key: string;
  etag: string | null;
  last_data: string | null;
  last_polled: number;
  poll_count: number;
}

export class PollManager {
  constructor(
    private db: Database.Database,
    private fetchFn: FetchFn = globalThis.fetch
  ) {}

  async poll(
    resourceKey: string,
    url: string,
    headers: Record<string, string> = {}
  ): Promise<{ changed: boolean; data?: unknown }> {
    const state = this.getState(resourceKey);
    const reqHeaders: Record<string, string> = { ...headers };
    if (state?.etag) {
      reqHeaders['If-None-Match'] = state.etag;
    }

    const response = await this.fetchFn(url, { headers: reqHeaders });

    if (response.status === 304) {
      this.updatePollTime(resourceKey);
      return { changed: false };
    }

    const etag = response.headers.get('etag');
    const data = await response.json();
    this.saveState(resourceKey, etag, JSON.stringify(data));
    return { changed: true, data };
  }

  async pollGitHubUnresolvedComments(
    repo: string,
    prNumber: number,
    token?: string
  ): Promise<void> {
    const resourceKey = `github:${repo}:pr:${prNumber}:comments`;
    const url = `https://api.github.com/repos/${repo}/pulls/${prNumber}/comments`;
    const headers: Record<string, string> = {
      Accept: 'application/vnd.github.v3+json',
    };
    if (token) headers.Authorization = `Bearer ${token}`;

    const result = await this.poll(resourceKey, url, headers);
    if (!result.changed || !result.data) return;

    const comments = result.data as Array<{
      id: number;
      body: string;
      user: { login: string };
      path: string;
      line: number | null;
      created_at: string;
    }>;

    if (comments.length === 0) return;

    const event: HydraEvent = {
      id: randomUUID(),
      source: 'github',
      event_type: 'pr.comments.unresolved_summary',
      priority: 'high',
      status: 'pending',
      project_id: null,
      payload: JSON.stringify({
        repo,
        pr_number: prNumber,
        comments: comments.map((c) => ({
          id: c.id,
          body: c.body,
          author: c.user.login,
          file_path: c.path,
          line: c.line,
        })),
      }),
      metadata: JSON.stringify({ total_comments: comments.length }),
      created_at: Date.now(),
      processed_at: null,
      completed_at: null,
      retry_count: 0,
    };

    insertEvent(this.db, event);
  }

  private getState(key: string): PollState | null {
    const stmt = this.db.prepare(
      'SELECT * FROM poll_state WHERE resource_key = ?'
    );
    return (stmt.get(key) as PollState) ?? null;
  }

  private saveState(key: string, etag: string | null, data: string): void {
    const stmt = this.db.prepare(`
      INSERT INTO poll_state (resource_key, etag, last_data, last_polled, poll_count)
      VALUES (?, ?, ?, ?, 1)
      ON CONFLICT(resource_key) DO UPDATE SET
        etag = excluded.etag,
        last_data = excluded.last_data,
        last_polled = excluded.last_polled,
        poll_count = poll_count + 1
    `);
    stmt.run(key, etag, data, Date.now());
  }

  private updatePollTime(key: string): void {
    this.db
      .prepare(
        'UPDATE poll_state SET last_polled = ?, poll_count = poll_count + 1 WHERE resource_key = ?'
      )
      .run(Date.now(), key);
  }
}
```

**Step 4: Run tests**

```bash
cd mcp-server && npx vitest run src/polling/polling.test.ts
```
Expected: all tests PASS.

**Step 5: Commit**

```bash
git add mcp-server/src/polling/
git commit -m "feat: add ETag-based polling manager for PR comment tracking"
```

---

### Task 6: Wire MCP + HTTP Together & Integration Test

**Files:**
- Modify: `mcp-server/src/index.ts`
- Test: `mcp-server/src/integration.test.ts`

**Step 1: Write integration test**

Create `mcp-server/src/integration.test.ts`:

```typescript
import { describe, it, expect, beforeEach } from 'vitest';
import request from 'supertest';
import { createApp } from './server.js';
import { createDb, getEventById } from './db.js';
import { handleGetPendingEvents } from './tools/get-pending-events.js';
import { handleAcknowledgeEvent } from './tools/acknowledge-event.js';
import { handleCompleteEvent } from './tools/complete-event.js';
import { handleEmitEvent } from './tools/emit-event.js';

describe('end-to-end: webhook to MCP tool flow', () => {
  let app: ReturnType<typeof createApp>;
  let db: ReturnType<typeof createDb>;

  beforeEach(() => {
    db = createDb(':memory:');
    app = createApp(db, { skipAuth: true });
  });

  it('full lifecycle: ingest, query, acknowledge, complete', async () => {
    // 1. Ingest via webhook
    const webhookRes = await request(app)
      .post('/webhooks/custom')
      .send({
        source: 'ci',
        event_type: 'build.failed',
        priority: 'critical',
        payload: { build_id: 'B-123', logs_url: 'https://ci.example.com/B-123' },
      })
      .expect(201);

    const eventId = webhookRes.body.event_id;

    // 2. Query pending events via tool handler
    const pending = handleGetPendingEvents(db, {});
    expect(pending).toHaveLength(1);
    expect(pending[0].id).toBe(eventId);
    expect(pending[0].priority).toBe('critical');

    // 3. Acknowledge
    const ackResult = handleAcknowledgeEvent(db, { event_id: eventId });
    expect(ackResult.success).toBe(true);

    // Verify no longer pending
    const pendingAfterAck = handleGetPendingEvents(db, {});
    expect(pendingAfterAck).toHaveLength(0);

    // 4. Complete
    const completeResult = handleCompleteEvent(db, {
      event_id: eventId,
      status: 'done',
    });
    expect(completeResult.success).toBe(true);

    const final = getEventById(db, eventId);
    expect(final!.status).toBe('done');
    expect(final!.completed_at).not.toBeNull();
  });

  it('event chaining: agent emits follow-up event', async () => {
    // Ingest original event
    await request(app)
      .post('/webhooks/custom')
      .send({ source: 'ci', event_type: 'build.failed', payload: {} })
      .expect(201);

    // Agent processes and emits follow-up
    handleEmitEvent(db, {
      source: 'internal',
      event_type: 'diagnosis.ready',
      priority: 'high',
      payload: '{"diagnosis":"missing dependency"}',
    });

    // Both events now in queue
    const all = handleGetPendingEvents(db, {});
    expect(all).toHaveLength(2);
    expect(all.some((e) => e.event_type === 'diagnosis.ready')).toBe(true);
  });
});
```

**Step 2: Run integration test**

```bash
cd mcp-server && npx vitest run src/integration.test.ts
```
Expected: all tests PASS.

**Step 3: Update `mcp-server/src/index.ts` to optionally start HTTP server**

Append to the end of `index.ts` (after `await server.connect(transport);`):

```typescript
import { createApp } from './server.js';

// Start HTTP webhook server if WEBHOOK_PORT is set
const webhookPort = process.env.HYDRA_WEBHOOK_PORT;
if (webhookPort) {
  const app = createApp(db, {
    githubSecret: process.env.GITHUB_WEBHOOK_SECRET,
    apiToken: process.env.HYDRA_API_TOKEN,
  });
  app.listen(parseInt(webhookPort, 10), '127.0.0.1', () => {
    console.error(
      `Hydra webhook server listening on http://127.0.0.1:${webhookPort}`
    );
  });
}
```

**Step 4: Run all tests**

```bash
cd mcp-server && npx vitest run
```
Expected: all tests across all files PASS.

**Step 5: Commit**

```bash
git add mcp-server/src/integration.test.ts mcp-server/src/index.ts
git commit -m "feat: wire MCP and HTTP servers together with integration tests"
```

---

### Task 7: Plugin-Side Event Router (Shell)

**Files:**
- Create: `scripts/event-router.sh`
- Create: `templates/notification-routes.json`
- Test: `tests/test-event-router.sh`

**Step 1: Write the test**

Create `tests/test-event-router.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_NAME="test-event-router"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"

echo "=== $TEST_NAME ==="

ROUTER="$REPO_ROOT/scripts/event-router.sh"

# Test: match_route function — exact source + glob event_type
result=$(bash "$ROUTER" --test-match '{"source":"github","event_type":"pr.opened"}' '{"source":"github","event_type":"pr.*"}')
assert_eq "github pr.* matches pr.opened" "$result" "match"

result=$(bash "$ROUTER" --test-match '{"source":"ci","event_type":"build.failed"}' '{"source":"github","event_type":"pr.*"}')
assert_eq "github pr.* does not match ci build.failed" "$result" "no_match"

result=$(bash "$ROUTER" --test-match '{"source":"ci","event_type":"deployment.completed"}' '{"source":"*","event_type":"deployment.*"}')
assert_eq "wildcard source matches any" "$result" "match"

# Test: route config validation
assert_file_exists "notification-routes template exists" "$REPO_ROOT/templates/notification-routes.json"

# Validate JSON
if jq empty "$REPO_ROOT/templates/notification-routes.json" 2>/dev/null; then
  _pass "notification-routes.json is valid JSON"
else
  _fail "notification-routes.json is valid JSON"
fi

# Check required fields
assert_json_field "routes array exists" "$REPO_ROOT/templates/notification-routes.json" '.routes | type' "array"
assert_json_field "fallback_agent defined" "$REPO_ROOT/templates/notification-routes.json" '.fallback_agent' "discovery"

report_results
```

**Step 2: Run test to verify it fails**

```bash
bash tests/test-event-router.sh
```
Expected: FAIL — scripts and templates don't exist yet.

**Step 3: Create the routing config template**

`templates/notification-routes.json`:
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

**Step 4: Create the event router script**

`scripts/event-router.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Hydra Event Router — matches events to agents using glob patterns
# Usage:
#   event-router.sh --test-match '<event_json>' '<match_json>'
#   event-router.sh --route '<event_json>' '<routes_file>'

glob_match() {
  local value="$1"
  local pattern="$2"
  local regex
  regex=$(printf '%s' "$pattern" | jq -Rr 'gsub("\\."; "\\\\.") | gsub("\\*"; "[^.]*")')
  regex="^${regex}$"
  printf '%s' "$value" | grep -qE "$regex" && return 0 || return 1
}

match_route() {
  local event_source="$1"
  local event_type="$2"
  local match_source="$3"
  local match_type="$4"

  if [ "$match_source" != "*" ] && [ "$match_source" != "$event_source" ]; then
    echo "no_match"
    return
  fi

  if glob_match "$event_type" "$match_type"; then
    echo "match"
  else
    echo "no_match"
  fi
}

if [ "${1:-}" = "--test-match" ]; then
  event_json="$2"
  match_json="$3"
  event_source=$(printf '%s' "$event_json" | jq -r '.source')
  event_type=$(printf '%s' "$event_json" | jq -r '.event_type')
  match_source=$(printf '%s' "$match_json" | jq -r '.source')
  match_type=$(printf '%s' "$match_json" | jq -r '.event_type')
  match_route "$event_source" "$event_type" "$match_source" "$match_type"
  exit 0
fi

if [ "${1:-}" = "--route" ]; then
  event_json="$2"
  routes_file="$3"
  event_source=$(printf '%s' "$event_json" | jq -r '.source')
  event_type=$(printf '%s' "$event_json" | jq -r '.event_type')

  route_count=$(jq '.routes | length' "$routes_file")
  matched_agents="[]"

  for ((i = 0; i < route_count; i++)); do
    match_source=$(jq -r ".routes[$i].match.source" "$routes_file")
    match_type=$(jq -r ".routes[$i].match.event_type" "$routes_file")

    result=$(match_route "$event_source" "$event_type" "$match_source" "$match_type")
    if [ "$result" = "match" ]; then
      agents=$(jq -c ".routes[$i].agents" "$routes_file")
      matched_agents=$(printf '%s\n%s' "$matched_agents" "$agents" | jq -s 'add | unique')
    fi
  done

  if [ "$(printf '%s' "$matched_agents" | jq 'length')" -eq 0 ]; then
    fallback=$(jq -r '.fallback_agent' "$routes_file")
    matched_agents=$(jq -nc --arg a "$fallback" '[$a]')
  fi

  printf '%s' "$matched_agents"
  exit 0
fi

echo "Usage: event-router.sh --test-match '<event>' '<match>' | --route '<event>' '<routes_file>'" >&2
exit 1
```

**Step 5: Make executable**

```bash
chmod +x scripts/event-router.sh
```

**Step 6: Run test**

```bash
bash tests/test-event-router.sh
```
Expected: all tests PASS.

**Step 7: Commit**

```bash
git add scripts/event-router.sh templates/notification-routes.json tests/test-event-router.sh
git commit -m "feat: add shell-based event router with glob matching and routing config"
```

---

### Task 8: `/hydra-notify` Skill

**Files:**
- Create: `skills/hydra-notify/SKILL.md`

**Step 1: Create the skill**

`skills/hydra-notify/SKILL.md`:
```markdown
---
name: hydra-notify
description: Process pending notification events — route to Hydra agents and execute actions
allowed-tools:
  - Bash
  - Read
  - Write
  - Glob
  - Grep
  - Task
  - TaskCreate
  - TaskUpdate
  - TaskList
  - ToolSearch
context: fork
---

# Hydra Notify — Process Pending Events

## Pre-flight

1. Check if `hydra/config.json` exists. If not: "Hydra not initialized. Run `/hydra-init` first." STOP.
2. Check if notifications are enabled in config (`notifications.enabled`). If not: "Notifications are disabled. Enable in hydra/config.json." STOP.
3. Verify the MCP server `hydra-notifications` is available by calling `get_pending_events`. If it fails: "MCP server not running. Start it with `npm start` in mcp-server/." STOP.

## Process

1. Call `get_pending_events` MCP tool to fetch all pending events.
2. If no events: "No pending events." STOP.
3. For each event:
   a. Read `hydra/notification-routes.json` to determine target agents.
   b. Call `acknowledge_event` to claim the event.
   c. Display the event summary to the user.
   d. Spawn the matched agent(s) with event context.
   e. After agent completes, call `complete_event` with result.
4. Display summary of all processed events.

## Arguments

- `--source <source>` — Only process events from this source (github, ci, slack, etc.)
- `--dry-run` — Show what would be processed without actually routing to agents

## Output

Show a summary after processing:
- Event type and source
- Which agents were routed to
- Status (done/failed)
```

**Step 2: Run existing frontmatter test to verify skill is valid**

```bash
bash tests/test-frontmatter.sh
```
Expected: PASS (new skill has name, description fields).

**Step 3: Commit**

```bash
git add skills/hydra-notify/
git commit -m "feat: add /hydra-notify skill for processing pending events"
```

---

### Task 9: Full Test Suite Run & Cleanup

**Step 1: Run MCP server tests**

```bash
cd mcp-server && npx vitest run
```
Expected: all tests PASS.

**Step 2: Run plugin tests**

```bash
bash tests/run-tests.sh
```
Expected: all tests PASS.

**Step 3: Type check**

```bash
cd mcp-server && npx tsc --noEmit
```
Expected: no errors.

**Step 4: Build**

```bash
cd mcp-server && npm run build
```
Expected: `dist/` output with no errors.

**Step 5: Add `.gitignore` for MCP server artifacts**

Create `mcp-server/.gitignore`:
```
node_modules/
dist/
*.db
```

**Step 6: Final commit**

```bash
git add mcp-server/.gitignore
git commit -m "chore: add gitignore for MCP server build artifacts"
```

---

## Summary

| Task | What It Builds | Files | Tests |
|------|---------------|-------|-------|
| 1 | Project scaffold | 4 created | compile check |
| 2 | SQLite database layer | 3 created | 5 unit tests |
| 3 | MCP tools (6 tools) | 8 created, 1 modified | 7 unit tests |
| 4 | Webhook HTTP server | 5 created | 4 unit tests |
| 5 | ETag polling manager | 2 created | 3 unit tests |
| 6 | Integration wiring | 1 created, 1 modified | 2 integration tests |
| 7 | Shell event router | 2 created, 1 test | 5 assertions |
| 8 | `/hydra-notify` skill | 1 created | frontmatter check |
| 9 | Full suite + cleanup | 1 created | all suites |

**Total: ~27 files, 9 commits, 25+ tests**
