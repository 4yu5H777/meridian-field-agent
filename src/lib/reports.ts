// Team questions from managers and the regional head. Pure, so it can be
// unit-tested; the database call is passed in.
//
// meridian.meridian_report() decides who is asking (from the platform
// contacts), what they may see, the dates, and every figure. This file only
// checks the request shape and adds a formatted rupee string beside every
// *_paise number, so the model quotes money instead of converting it.
import type { SenderContext } from './identity.ts';
import { formatRupees } from './confirmation.ts';
import { renderReport, allowedNumbers } from './reportText.ts';

export const REPORTS = ['orders_summary', 'pending_approvals', 'dispatch_status', 'over_limit_chemists', 'rep_comparison'] as const;
export const PERIODS = ['today', 'yesterday', 'last_7_days', 'previous_7_days', 'this_week', 'this_month', 'custom'] as const;
export type ReportName = typeof REPORTS[number];

export type ReportInput = { report: string; period?: string; from?: string; to?: string; rep?: string; area?: string };
export type ReportResult =
  | { status: 'ok'; answer: unknown; answer_text: string; message: string; guard?: { text: string; allowed: string[] } }
  | { status: 'refused' | 'not_found' | 'ambiguous' | 'invalid' | 'error'; message: string; candidates?: string[] };

export const MSG_REFUSED = 'Sorry, I cannot help with that.';
const MSG_OK = 'Reply with answer_text. You may add one short sentence of your own, but every number you write must appear in answer_text: a reply with any other number is replaced by answer_text before it is sent.';

// Every "<name>_paise" integer gets a "<name>_rs" string next to it, recursively.
export function withRupees(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(withRupees);
  if (v && typeof v === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      out[k] = withRupees(val);
      if (k.endsWith('_paise') && typeof val === 'number' && Number.isSafeInteger(val)) {
        out[`${k.slice(0, -'_paise'.length)}_rs`] = formatRupees(val);
      }
    }
    return out;
  }
  return v;
}

const short = (s: unknown, n: number) => (typeof s === 'string' ? s.replace(/\s+/g, ' ').trim().slice(0, n) : undefined);

export async function runReport(
  input: ReportInput,
  sender: SenderContext,
  query: (channel: 'whatsapp' | 'email', contacts: string[], report: string, params: Record<string, string>) => Promise<unknown>,
): Promise<ReportResult> {
  if (!sender.ok) return { status: 'refused', message: MSG_REFUSED };
  if (!REPORTS.includes(input?.report as ReportName)) return { status: 'invalid', message: `report must be one of: ${REPORTS.join(', ')}` };
  const period = input.period ?? 'today';
  if (!PERIODS.includes(period as typeof PERIODS[number])) return { status: 'invalid', message: `period must be one of: ${PERIODS.join(', ')}` };
  const params: Record<string, string> = { period };
  for (const k of ['from', 'to'] as const) {
    const v = short(input[k], 10);
    if (v) params[k] = v;
  }
  for (const k of ['rep', 'area'] as const) {
    const v = short(input[k], 80);
    if (v) params[k] = v;
  }
  try {
    const r = await query(sender.channel, sender.contacts, input.report, params) as Record<string, any>;
    if (r?.ok === true) {
      const answer = withRupees(r);
      const text = renderReport(answer);
      // guard: what the report-integrity postprocessor checks the reply against (not for the model).
      return { status: 'ok', answer, answer_text: text, message: MSG_OK, guard: { text, allowed: allowedNumbers(answer, text) } };
    }
    switch (r?.error) {
      case 'not_identified': return { status: 'refused', message: MSG_REFUSED };
      case 'rep_not_found': return { status: 'not_found', message: 'No rep by that name in your scope.' };
      case 'area_not_found': return { status: 'not_found', message: 'No area by that name in your scope.' };
      case 'ambiguous_rep': return { status: 'ambiguous', message: 'More than one rep matches; ask which one.',
                                     candidates: Array.isArray(r.candidates) ? r.candidates.slice(0, 10).map(String) : [] };
      case 'rep_required': return { status: 'invalid', message: 'This comparison needs a rep name.' };
      case 'bad_period': return { status: 'invalid', message: 'That period is not supported (custom ranges: up to 92 days, not in the future).' };
      default: return { status: 'error', message: 'I could not get those figures just now.' };
    }
  } catch {
    return { status: 'error', message: 'I could not get those figures just now.' };
  }
}
