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
