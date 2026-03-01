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
