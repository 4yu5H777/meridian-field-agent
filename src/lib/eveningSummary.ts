// The 7 PM evening email. Pure, so it can be unit-tested.
//
// meridian.evening_summary() computes every figure (scope, counts, values,
// waiting approvals, off-route orders) and the outbox holds that snapshot.
// This file only formats it; there is no arithmetic here. Incomplete data
// throws, so the dispatcher records a failure instead of sending a wrong email.
import { formatRupees } from './confirmation.ts';
import { SummaryDataError } from './summary.ts';

// When the job runs: every day at 19:00 India time. The business date is taken
// by the database (ist_date(now())), so a late or repeated run cannot pick the
// wrong day or send twice.
export const EVENING_SUMMARY_SCHEDULE = { type: 'cron' as const, expression: '0 19 * * *', timezone: 'Asia/Kolkata' };

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
export function formatDate(iso: unknown): string {
  const m = typeof iso === 'string' ? /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso) : null;
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) throw new SummaryDataError('date');
  return `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}`;
}

const STATUS_LABEL: Record<string, string> = {
  confirmed: 'confirmed, not yet sent', awaiting_credit_approval: 'awaiting credit approval', credit_rejected: 'credit rejected',
  submitted: 'sent to distributor', accepted: 'accepted by distributor', dispatched: 'dispatched',
  distributor_rejected: 'rejected by distributor', cancelled: 'cancelled',
};
const label = (s: unknown) => (typeof s === 'string' && STATUS_LABEL[s]) || String(s).replace(/_/g, ' ');

const isInt = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
const isStr = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 200;
const need = (ok: boolean, what: string) => { if (!ok) throw new SummaryDataError(what); };
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

export function renderEveningSummary(p: any): { subject: string; text: string } {
  need(!!p && typeof p === 'object', 'payload');
  const date = formatDate(p.date);
  const v = p.viewer;
  need(!!v && isStr(v.name) && (v.role === 'area_manager' || v.role === 'regional_head'), 'viewer');
  const head = v.role === 'regional_head';
  need(head || isStr(v.area), 'viewer area');
  const t = p.team;
  need(!!t && isInt(t.reps) && isInt(t.orders) && isInt(t.value_paise) && isInt(t.off_route) && !!t.by_status && typeof t.by_status === 'object', 'team');
  need(Array.isArray(p.reps) && Array.isArray(p.waiting) && Array.isArray(p.off_route_orders), 'lists');
  for (const r of p.reps) need(isStr(r?.name) && isInt(r.orders) && isInt(r.value_paise) && isInt(r.off_route), 'rep row');
  for (const w of p.waiting) need(isInt(w?.order_id) && isStr(w.chemist) && isStr(w.rep) && isInt(w.total_paise) && isInt(w.over_by_paise) && isStr(w.token), 'waiting row');
  for (const o of p.off_route_orders) need(isInt(o?.order_id) && isStr(o.chemist) && isStr(o.rep) && isInt(o.total_paise), 'off-route row');

  const scope = head ? 'all teams' : v.area;
  const out: string[] = [`Dear ${v.name},`, ''];
  out.push(`${head ? 'Orders across all teams' : 'Your team\'s orders'} on ${date} (${scope}, ${plural(t.reps, 'rep', 'reps')}):`);
  if (t.orders === 0) {
    out.push(head ? 'No orders were confirmed today.' : 'No orders from your team today.');
  } else {
    out.push(`Orders confirmed: ${t.orders}   Value: ${formatRupees(t.value_paise)}   Off route: ${t.off_route}`);
    const byStatus = Object.entries(t.by_status as Record<string, number>).sort(([a], [b]) => a.localeCompare(b))
      .map(([s, n]) => `${label(s)} ${n}`);
    out.push(`By status: ${byStatus.join(', ')}`);
    out.push('', 'By rep:');
    for (const r of p.reps.filter((r: any) => r.orders > 0)) {
      out.push(`- ${r.name}${head && r.area ? ` (${r.area})` : ''}: ${plural(r.orders, 'order', 'orders')}, ${formatRupees(r.value_paise)}${r.off_route ? `, ${r.off_route} off route` : ''}`);
    }
    const idle = p.reps.filter((r: any) => r.orders === 0).map((r: any) => r.name);
    if (idle.length) out.push(`- No orders today: ${idle.join(', ')}`);
  }

  out.push('', head ? 'Waiting on area managers (credit approval):' : 'Waiting on you (credit approval):');
  if (p.waiting.length === 0) out.push(head ? 'Nothing is waiting.' : 'Nothing is waiting on you.');
  for (const w of p.waiting) {
    out.push(`- Order #${w.order_id}, ${w.chemist} (${w.rep}): ${formatRupees(w.total_paise)}, over the limit by ${formatRupees(w.over_by_paise)}.`
      + `${w.requested_ist ? ` Requested ${w.requested_ist}.` : ''}${head && w.manager ? ` With ${w.manager}.` : ` Reply to the approval email [${w.token}].`}`);
  }

  out.push('', 'Off-route orders today:');
  if (p.off_route_orders.length === 0) out.push('No off-route orders today.');
  for (const o of p.off_route_orders) out.push(`- Order #${o.order_id}, ${o.chemist} (${o.rep}): ${formatRupees(o.total_paise)}, ${label(o.status)}`);

  out.push('', 'Figures are taken from Meridian\'s order records at 7 PM India time.');
  return { subject: `Meridian evening summary for ${date}: ${scope}`, text: out.join('\n') };
}
