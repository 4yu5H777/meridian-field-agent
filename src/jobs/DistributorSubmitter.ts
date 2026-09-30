import { LuaJob, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { submitOrders } from '../lib/submit.ts';
import { distributorSender } from '../lib/distributorClient.ts';
import { systemDb, type Query } from '../lib/meridianDb.ts';

// Every minute: send confirmed orders to the distributor and record its
// reference. The database decides which orders may go and re-checks the
// guard when recording. SYSTEM_DATABASE_URL, DISTRIBUTOR_URL, DISTRIBUTOR_API_KEY.
export default new LuaJob({
  name: 'distributor-submitter',
  description: 'Sends confirmed Meridian orders to the distributor and records the distributor reference.',
  schedule: { type: 'interval', seconds: 60 },
  timeout: 120,
  async execute() {
    const dbUrl = env('SYSTEM_DATABASE_URL');
    const distUrl = env('DISTRIBUTOR_URL');
    const distKey = env('DISTRIBUTOR_API_KEY');
    if (!dbUrl || !distUrl || !distKey) {
      console.error('distributor-submitter: SYSTEM_DATABASE_URL, DISTRIBUTOR_URL or DISTRIBUTOR_API_KEY is not set');
      return { claimed: 0, submitted: 0, retrying: 0, refused: 0, results: [], error: 'not configured' };
    }
    const q: Query = async (text, params) => await neon(dbUrl).query(text, params) as Record<string, unknown>[];
    const db = systemDb(q);
    const report = await submitOrders({
      claim: db.claimSubmissions, send: distributorSender(distUrl, distKey), record: db.submitOrder, fail: db.failSubmission,
      limit: 10, sendTimeoutMs: 20_000,
    });
    console.info(`distributor-submitter: claimed ${report.claimed}, submitted ${report.submitted}, retrying ${report.retrying}, refused ${report.refused}${report.error ? `, ${report.error}` : ''}`);
    return report;
  },
});
