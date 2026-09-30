// A manager's numbers are never the model's. team_report's answer is rendered
// here, deterministically, from meridian_report(); the report-integrity
// postprocessor then checks every number in the model's reply against the
// numbers this answer contains, and sends this text instead when any number
// does not match (a rounding, a sum, a percentage, a typo, a made-up figure).
//
// Pure, so it is unit-tested directly.
import { formatRupees } from './confirmation.ts';

// Where team_report leaves this turn's figures for the postprocessor (Lua user data).
export const REPORT_GUARD_KEY = 'meridian_report_guard';
export const GUARD_TTL_MS = 10 * 60_000;
export type ReportGuard = { at: number; text: string; allowed: string[] };

type J = Record<string, any>;
const rs = (p: unknown) => formatRupees(p as number);
const n = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
const list = (v: unknown): J[] => (Array.isArray(v) ? v.filter((x) => x && typeof x === 'object') : []);
const signedRs = (p: unknown) => (n(p) > 0 ? `+${rs(p)}` : rs(p));
const signed = (v: unknown) => (n(v) > 0 ? `+${n(v)}` : String(n(v)));

function heading(a: J, title: string): string {
  const p = a.period ?? {};
  const range = p.from && p.to ? (p.from === p.to ? ` (${p.from})` : ` (${p.from} to ${p.to})`) : '';
  return `${title}${range}, ${a.scope ?? ''}:`;
}

export function renderReport(answer: unknown): string {
  const a = (answer && typeof answer === 'object' ? answer : {}) as J;
  const d = (a.data ?? {}) as J;
  const out: string[] = [];
  switch (a.report) {
    case 'orders_summary': {
      out.push(heading(a, `Orders${a.rep_filter ? ` for ${a.rep_filter}` : ''}`));
      out.push(`${n(d.orders)} orders worth ${rs(d.value_paise)}; ${n(d.off_route)} off route.`);
      const st = Object.entries((d.by_status ?? {}) as Record<string, number>).map(([k, v]) => `${k.replace(/_/g, ' ')} ${n(v)}`);
      if (st.length) out.push(`By status: ${st.join(', ')}.`);
      for (const r of list(d.reps)) out.push(`- ${r.name}: ${n(r.orders)} orders, ${rs(r.value_paise)}, ${n(r.off_route)} off route`);
      if (d.reps_without_orders !== undefined) out.push(`Reps with no orders: ${n(d.reps_without_orders)}.`);
      break;
    }
    case 'pending_approvals': {
      out.push(`Orders waiting for credit approval, ${a.scope ?? ''}: ${n(d.count)}${n(d.count) ? `, total ${rs(d.total_paise)}` : ''}.`);
      for (const x of list(d.approvals)) {
        out.push(`- Order ${x.order_id}: ${x.rep} for ${x.chemist}, ${rs(x.total_paise)} (over the limit by ${rs(x.over_by_paise)}), waiting for ${x.manager} since ${x.requested_ist}`);
      }
      break;
    }
    case 'dispatch_status': {
      out.push(heading(a, 'Distributor status'));
      out.push(`${n(d.sent_to_distributor)} sent: ${n(d.dispatched)} dispatched, ${n(d.accepted)} accepted, ${n(d.awaiting_distributor)} awaiting the distributor, ${n(d.rejected_by_distributor)} rejected.`);
      const waiting = list(d.not_yet_dispatched);
      if (waiting.length) out.push('Not dispatched yet:');
      for (const x of waiting) out.push(`- Order ${x.order_id}: ${x.chemist} (${x.rep}), ${String(x.status).replace(/_/g, ' ')}, ${rs(x.total_paise)}, sent ${x.sent_ist}, ref ${x.distributor_ref}`);
      break;
    }
    case 'over_limit_chemists': {
      out.push(`Chemists over their credit limit, ${a.scope ?? ''}: ${n(d.count)}.`);
      for (const c of list(d.chemists)) out.push(`- ${c.chemist} (${c.area}): owes ${rs(c.owed_paise)} against a limit of ${rs(c.limit_paise)}, over by ${rs(c.over_by_paise)}`);
      break;
    }
    case 'rep_comparison': {
      const c = (d.current ?? {}) as J;
      const p = (d.previous ?? {}) as J;
      out.push(`${d.rep}: ${c.from} to ${c.to} compared with ${p.from} to ${p.to}.`);
      out.push(`Orders: ${n(c.orders)} vs ${n(p.orders)} (${signed(d.change_orders)}).`);
      out.push(`Value: ${rs(c.value_paise)} vs ${rs(p.value_paise)} (${signedRs(d.change_value_paise)}).`);
      out.push(`Off route: ${n(c.off_route)} vs ${n(p.off_route)}. Credit rejected: ${n(c.credit_rejected)} vs ${n(p.credit_rejected)}. Rejected by the distributor: ${n(c.distributor_rejected)} vs ${n(p.distributor_rejected)}.`);
      break;
    }
    default:
      out.push('No figures.');
  }
  return out.join('\n');
}

// ------------------------------------------------------------------ number check
// A number as written: "₹1,23,456.50", "Rs. 1660", "-2", "17,604", "09".
const NUMBER = /(?:₹|\brs\.?\s*|\binr\s*)?-?\d[\d,]*(?:\.\d+)?/gi;

// Canonical key: the value in hundredths, sign dropped ("down by 2" and "-2"
// state the same figure), so ₹1,660, 1660.00 and 1,660 all match.
function key(token: string): string | null {
  const digits = token.replace(/₹|rs\.?|inr|,|\s|-/gi, '');
  if (!/^\d+(\.\d+)?$/.test(digits)) return null;
  const v = Math.round(Number(digits) * 100);
  return Number.isFinite(v) ? String(v) : null;
}

function numbersOf(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(NUMBER)) {
    const k = key(m[0]);
    if (k !== null) out.push(k);
  }
  return out;
}

// Every figure the answer states, in any of the forms the model may use.
export function allowedNumbers(answer: unknown, text = renderReport(answer)): string[] {
  const set = new Set<string>(numbersOf(text));
  const walk = (v: unknown, k = '', depth = 0): void => {
    if (depth > 8) return;
    if (typeof v === 'number' && Number.isFinite(v)) {
      // Keys are hundredths of the value as written. A paise figure IS the
      // hundredths of its rupee value, so it must not also be allowed x100
      // (that would let "₹1,66,000" pass for ₹1,660.00).
      set.add(String(Math.round(Math.abs(v) * (k.endsWith('_paise') ? 1 : 100))));
    } else if (typeof v === 'string') numbersOf(v).forEach((x) => set.add(x));
    else if (Array.isArray(v)) v.forEach((x) => walk(x, k, depth + 1));
    else if (v && typeof v === 'object') Object.entries(v).forEach(([kk, x]) => walk(x, kk, depth + 1));
  };
  walk(answer);
  return [...set];
}

// The reply's numbers that the report does not contain. A list marker at the
// start of a line ("1." / "2)") is not a figure.
export function unsupportedNumbers(reply: string, allowed: readonly string[]): string[] {
  const ok = new Set(allowed);
  const withoutMarkers = reply.replace(/^\s*\d{1,2}[.)]\s/gm, ' ');
  return [...new Set(numbersOf(withoutMarkers))].filter((k) => !ok.has(k));
}

// What the postprocessor sends: the model's reply when every number checks
// out, otherwise the deterministic answer.
export function enforceReportNumbers(reply: string, guard: { text: string; allowed: readonly string[] }): { text: string; replaced: boolean; bad: string[] } {
  const bad = unsupportedNumbers(reply, guard.allowed);
  return bad.length === 0 ? { text: reply, replaced: false, bad } : { text: guard.text, replaced: true, bad };
}

// The whole postprocessor decision for one reply. `stored` is whatever is in
// user data (untrusted shape). No guard, or an old one: the reply is not a
// report answer and is left alone. A reply carrying an order summary's YES
// line belongs to summary-integrity and is left alone.
export function checkReportReply(reply: string, stored: unknown, now: number): { text: string; consume: boolean; log: string } {
  const g = stored as Partial<ReportGuard> | null | undefined;
  if (!g || typeof g !== 'object' || typeof g.text !== 'string' || !Array.isArray(g.allowed) || typeof g.at !== 'number') {
    return { text: reply, consume: false, log: 'no report this turn' };
  }
  if (now - g.at > GUARD_TTL_MS || g.at > now + 60_000) return { text: reply, consume: true, log: 'stale report guard' };
  if (/\b(?:yes|haan|confirm)\s*[0-9]{4}\b/i.test(reply)) return { text: reply, consume: true, log: 'order summary reply; left to summary-integrity' };
  const r = enforceReportNumbers(reply, { text: g.text, allowed: g.allowed.filter((x) => typeof x === 'string') });
  return { text: r.text, consume: true, log: r.replaced ? `replaced: ${r.bad.length} number(s) not in the report` : 'numbers match the report' };
}
