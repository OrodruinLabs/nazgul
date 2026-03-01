import type { Request } from 'express';

export function verifyBearerToken(req: Request, expectedToken: string): boolean {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) return false;
  return header.slice(7) === expectedToken;
}
