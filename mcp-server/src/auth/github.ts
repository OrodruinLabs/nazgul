import { createHmac, timingSafeEqual } from 'node:crypto';
import type { Request } from 'express';

export function verifyGitHubSignature(req: Request, secret: string): boolean {
  const signature = req.headers['x-hub-signature-256'] as string | undefined;
  if (!signature) return false;
  const rawBody = (req as any).rawBody as Buffer;
  if (!rawBody) return false;
  const expected = 'sha256=' + createHmac('sha256', secret).update(rawBody).digest('hex');
  try {
    return timingSafeEqual(Buffer.from(signature), Buffer.from(expected));
  } catch {
    return false;
  }
}
