import { PostProcessor } from 'lua-cli';
import { checkReportReply, REPORT_GUARD_KEY } from '../lib/reportText.ts';

// A manager's figures are exactly the database's (src/lib/reportText.ts).
//
// team_report leaves this turn's figures in the user's data; this checks every
// number in the model's reply against them and sends the deterministic answer
// instead when any number is not one the report contains. The guard is used
// once and expires after 10 minutes, so later replies are not affected.
// Runs after summary-integrity (priority 2). Never throws and never returns ''
// (the platform would skip it or treat '' as no change): when the check itself
// fails, the stored deterministic answer is sent if there is one.
export default new PostProcessor({
  name: 'report-integrity',
  description: 'Replaces a manager answer whose numbers do not match the report it came from.',
  priority: 2,
  async execute(user, _message, response) {
    const reply = typeof response === 'string' ? response : '';
    let stored: unknown;
    try {
      stored = (user?.data as Record<string, unknown> | undefined)?.[REPORT_GUARD_KEY];
      const outcome = checkReportReply(reply, stored, Date.now());
      if (outcome.consume) {
        try { await user.unset(REPORT_GUARD_KEY); } catch { console.error('report-integrity: could not clear the guard'); }
      }
      console.info(`report-integrity: ${outcome.log}`);
      return { modifiedResponse: outcome.text || reply || ' ' };
    } catch {
      console.error('report-integrity: unexpected failure');
      const fallback = (stored as { text?: unknown } | undefined)?.text;
      return { modifiedResponse: typeof fallback === 'string' && fallback ? fallback : reply || ' ' };
    }
  },
});
