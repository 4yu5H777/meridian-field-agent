import { LuaWebhook, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { handleCallback } from '../lib/callback.ts';
import { systemDb, type Query } from '../lib/meridianDb.ts';
import { runDispatcher } from '../lib/dispatch.ts';

// The distributor's status callbacks: POST https://webhook.heylua.ai/<agentId>/distributor-callback
//
// No platform `secret` on purpose: that must be a literal in source. The
// signature is verified in code instead (src/lib/callback.ts) with
// DISTRIBUTOR_CALLBACK_SECRET from the environment. The database decides what
// the event means (record_distributor_event: idempotent, out-of-order and
// unknown-order safe) and queues the rep's notification, which is sent right
// away. Model never involved. SYSTEM_DATABASE_URL.
export default new LuaWebhook({
  name: 'distributor-callback',
  description: 'Records a signed distributor status update (accepted / dispatched / rejected) and tells the rep.',
  async execute(event) {
    const dbUrl = env('SYSTEM_DATABASE_URL');
    const q: Query = async (text, params) => {
      if (!dbUrl) throw new Error('SYSTEM_DATABASE_URL is not set');
      return await neon(dbUrl).query(text, params) as Record<string, unknown>[];
    };
    const db = systemDb(q);
    const res = await handleCallback({ headers: event?.headers, body: event?.body, secret: env('DISTRIBUTOR_CALLBACK_SECRET'),
                                       record: db.recordDistributorEvent, timeoutMs: 15_000 });
    console.info(`distributor-callback: ${res.ok ? res.result : res.error}`);
    if (res.ok && res.result === 'applied') {
      const report = await runDispatcher(10);
      console.info(`distributor-callback: dispatched ${report.sent}/${report.claimed}`);
    }
    return res;
  },
});
