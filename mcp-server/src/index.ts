import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { createDb } from './db.js';
import { createApp } from './server.js';
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
