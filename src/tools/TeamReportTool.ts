import { env, User } from 'lua-cli';
import type { LuaTool } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { z } from 'zod';
import { runReport, REPORTS, PERIODS, type ReportResult } from '../lib/reports.ts';
import { REPORT_GUARD_KEY } from '../lib/reportText.ts';
import { senderContext } from '../lib/identity.ts';
import { readInvoked, readRequestChannel } from '../lib/luaRequest.ts';

// The only way the model gets team figures: a fixed report name, a named
// period, optionally a rep or area name. No SQL, no ids, no viewer: who is
// asking comes from the platform profile, and the database decides what they
// may see. AGENT_DATABASE_URL only.
export default class TeamReportTool implements LuaTool {
  name = 'team_report';
  description =
    'Exact figures for a manager\'s or the regional head\'s question about orders, values, statuses, pending credit approvals, '
    + 'distributor dispatch status, chemists over their credit limit, or one rep\'s trend. Figures are limited to what the person asking may see.';
  inputSchema = z.object({
    report: z.enum(REPORTS).describe(
      'orders_summary: order count, value, status breakdown, off-route count, per rep. '
      + 'pending_approvals: orders waiting for credit approval. dispatch_status: sent / accepted / dispatched / rejected by the distributor. '
      + 'over_limit_chemists: chemists whose balance is over their credit limit (optional area). '
      + 'rep_comparison: one rep this period vs the same length just before (e.g. "why is Ravi down this week").'),
    period: z.enum(PERIODS).optional().describe('Default today. Use custom with from/to (YYYY-MM-DD) only for explicit dates.'),
    from: z.string().max(10).optional(),
    to: z.string().max(10).optional(),
    rep: z.string().max(80).optional().describe('A rep\'s name or employee code, as the person wrote it'),
    area: z.string().max(80).optional().describe('An area name such as "north" or "South Delhi", for over_limit_chemists'),
  });

  async execute(input: z.infer<typeof this.inputSchema>): Promise<ReportResult> {
    try {
      const channel = readRequestChannel();
      const user = await User.get();
      const sender = senderContext({ channel, requestChannel: channel, invoked: readInvoked(), profile: user?._luaProfile });
      const url = env('AGENT_DATABASE_URL');
      if (!url) return { status: 'error', message: 'I could not get those figures just now.' };
      const result = await runReport(input, sender, async (ch, contacts, report, params) => {
        const [r] = await neon(url).query('SELECT meridian.meridian_report($1, $2::text[], $3, $4::jsonb) AS r',
          [ch, contacts, report, JSON.stringify(params)]) as { r: unknown }[];
        return r?.r;
      });
      if (result.status !== 'ok') return result;
      // The figures this turn's reply will be checked against (report-integrity
      // postprocessor). Without it the reply could not be verified, so the model
      // gets only the fixed text to send.
      const { guard, ...forModel } = result;
      if (!guard) return { status: 'error', message: 'I could not get those figures just now.' };
      try {
        if (!user) throw new Error('no user');
        await user.update({ [REPORT_GUARD_KEY]: { at: Date.now(), text: guard.text, allowed: guard.allowed } });
        return forModel as ReportResult;
      } catch {
        return { status: 'ok', answer: null, answer_text: guard.text, message: 'Send answer_text exactly as given, with nothing added.' };
      }
    } catch {
      return { status: 'error', message: 'I could not get those figures just now.' };
    }
  }
}
