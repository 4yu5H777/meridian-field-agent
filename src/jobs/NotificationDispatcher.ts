import { LuaJob } from 'lua-cli';
import { runDispatcher } from '../lib/dispatch.ts';

// Every minute: send whatever the database has queued (approval emails to
// managers, decisions to reps). Leases and retries live in the database.
export default new LuaJob({
  name: 'notification-dispatcher',
  description: 'Sends queued Meridian notifications (credit approval emails, decisions to reps).',
  schedule: { type: 'interval', seconds: 60 },
  timeout: 120,
  async execute() {
    const report = await runDispatcher(25);
    console.info(`notification-dispatcher: claimed ${report.claimed}, sent ${report.sent}, failed ${report.failed}${report.error ? `, ${report.error}` : ''}`);
    return report;
  },
});
