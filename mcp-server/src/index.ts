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
  handleTriggerPoll,
} from './tools/index.js';
import { PollManager } from './polling/poll-manager.js';
import { PollScheduler } from './polling/scheduler.js';
import { getGitHubRepo } from './utils/git-remote.js';
import { getGitHubToken } from './utils/gh-token.js';

const DB_PATH = process.env.HYDRA_DB_PATH ?? './hydra/notifications.db';
const db = createDb(DB_PATH);
const poller = new PollManager(db);

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
    source: z.string().min(1),
    event_type: z.string().min(1),
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

server.registerTool('trigger_poll', {
  title: 'Trigger Poll',
  description: 'Manually trigger polling of GitHub APIs for new events',
  inputSchema: z.object({
    resource: z.enum(['comments', 'workflows', 'all']).optional(),
    pr_number: z.number().optional(),
  }),
}, async (input) => ({
  content: [{ type: 'text', text: JSON.stringify(await handleTriggerPoll(poller, input)) }],
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

// Start scheduled polling (default: every 300s; disable with HYDRA_POLL_INTERVAL=0)
const pollInterval = process.env.HYDRA_POLL_INTERVAL ?? '300';
{
  const seconds = parseInt(pollInterval, 10);
  if (!isNaN(seconds) && seconds > 0) {
    const repo = getGitHubRepo();
    if (repo) {
      const token = getGitHubToken();
      if (!token) {
        console.error('[hydra-poll] No GitHub token found (set GITHUB_TOKEN or run `gh auth login`) — skipping');
      }
      const scheduler = new PollScheduler(db, repo, token);
      scheduler.start(seconds);
      console.error(`[hydra-poll] Polling ${repo} every ${seconds}s`);

      // Cleanup on exit
      const cleanup = () => scheduler.stop();
      process.on('SIGINT', cleanup);
      process.on('SIGTERM', cleanup);
    } else {
      console.error('[hydra-poll] Not a GitHub repo — polling disabled');
    }
  }
}
