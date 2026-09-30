import { env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { dispatchNotifications, type DispatchReport } from './notify.ts';
import { systemDb, type Query } from './meridianDb.ts';
import { sendOutgoing } from './channelSend.ts';

// Drain due notifications with the system role. Used by the scheduled
// notification-dispatcher job and, right after a manager's decision, by the
// credit-reply gate. Never throws.
export async function runDispatcher(limit: number): Promise<DispatchReport> {
  const url = env('SYSTEM_DATABASE_URL');
  if (!url) return { claimed: 0, sent: 0, failed: 0, error: 'SYSTEM_DATABASE_URL is not set' };
  const q: Query = async (text, params) => await neon(url).query(text, params) as Record<string, unknown>[];
  const db = systemDb(q);
  return dispatchNotifications({
    claim: (n) => db.claim(n), complete: (id, ref) => db.complete(id, ref), fail: (id, e) => db.fail(id, e),
    send: sendOutgoing, limit, sendTimeoutMs: 20_000,
  });
}
