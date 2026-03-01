import { timingSafeEqual } from 'node:crypto';
import type { Request } from 'express';

export function verifyBearerToken(req: Request, expectedToken: string): boolean {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return false;
  const provided = header.slice(7);
  if (provided.length !== expectedToken.length) return false;
  return timingSafeEqual(Buffer.from(provided), Buffer.from(expectedToken));
}
