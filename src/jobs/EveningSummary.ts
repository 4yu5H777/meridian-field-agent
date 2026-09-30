import { LuaJob, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { EVENING_SUMMARY_SCHEDULE } from '../lib/eveningSummary.ts';
import { runDispatcher } from '../lib/dispatch.ts';

// 19:00 India time: queue one evening email per area manager and one for the
// regional head (meridian.enqueue_evening_summaries: figures from the
// database, once per recipient per day), then send them. SYSTEM_DATABASE_URL.
export default new LuaJob({
  name: 'evening-summary',
  description: 'Emails each area manager (and the regional head) the day\'s orders, approvals waiting and off-route orders.',
  schedule: EVENING_SUMMARY_SCHEDULE,
  timeout: 300,
  retry: { maxAttempts: 3, backoffSeconds: 120 },
  async execute() {
    const url = env('SYSTEM_DATABASE_URL');
    if (!url) {
      console.error('evening-summary: SYSTEM_DATABASE_URL is not set');
      return { queued: 0, error: 'not configured' };
    }
    const [r] = await neon(url).query('SELECT meridian.enqueue_evening_summaries(NULL) AS queued', []) as { queued: number }[];
    const report = await runDispatcher(50);
    console.info(`evening-summary: queued ${r?.queued ?? 0}, sent ${report.sent}/${report.claimed}`);
    return { queued: r?.queued ?? 0, ...report };
  },
});
