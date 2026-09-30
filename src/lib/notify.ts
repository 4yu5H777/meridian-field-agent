// Notifications queued by the database (meridian.notification_outbox) and how
// they are worded. Pure, so it can be unit-tested with plain Node.
//
// The database decides what is sent and to whom; the payload carries every
// figure. These builders only format: no arithmetic, and anything missing or
// malformed throws, so the dispatcher records a failure instead of sending a
// message with gaps.
import { formatRupees } from './confirmation.ts';
import { formatSummaryLines, SummaryDataError } from './summary.ts';
import { renderEveningSummary } from './eveningSummary.ts';

// luaUserId: the recipient's Lua user on that channel (lua_user_links), so a
// WhatsApp message can go back through Lua's shared test number with user.send().
export type OutgoingMessage = { channel: 'whatsapp' | 'email'; address: string; subject?: string; text: string; luaUserId?: string };
export type ClaimedNotification = { id: unknown; kind: unknown; channel: unknown; address: unknown; payload: unknown; attempts?: unknown; lua_user_id?: unknown };

const isInt = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);
const isStr = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 320;
const need = (ok: boolean, what: string) => { if (!ok) throw new SummaryDataError(what); };
const TOKEN = /^CR-[0-9A-F]{8}$/;

export function renderNotification(n: ClaimedNotification): OutgoingMessage {
  need(n.channel === 'whatsapp' || n.channel === 'email', 'channel');
  need(isStr(n.address), 'address');
  const channel = n.channel as 'whatsapp' | 'email';
  const address = n.address as string;
  const p = n.payload as Record<string, any>;
  need(!!p && typeof p === 'object', 'payload');

  if (n.kind === 'credit_approval_request') {
    // The manager decides by replying to THIS email; it must be an email.
    need(channel === 'email', 'approval requests go by email');
    need(TOKEN.test(p.token) && isInt(p.order_id) && isStr(p.manager_name) && isStr(p.rep_name), 'approval identity');
    need(!!p.chemist && isStr(p.chemist.name) && isStr(p.chemist.locality), 'approval chemist');
    need(isInt(p.order_total_paise) && isInt(p.owed_paise) && isInt(p.limit_paise) && isInt(p.over_by_paise), 'approval amounts');
    const text = [
      `Dear ${p.manager_name},`,
      '',
      `${p.rep_name} has confirmed an order that takes ${p.chemist.name}, ${p.chemist.locality} over its credit limit. It will not be sent to the distributor unless you approve it.`,
      '',
      `Order #${p.order_id}:`,
      ...formatSummaryLines(p.lines),
      '',
      `Order total:       ${formatRupees(p.order_total_paise)}`,
      `Already owed:      ${formatRupees(p.owed_paise)}`,
      `Credit limit:      ${formatRupees(p.limit_paise)}`,
      `Over the limit by: ${formatRupees(p.over_by_paise)}`,
      '',
      'Reply to this email with APPROVE or REJECT as the first line. You can add a note after it, for example "REJECT collect the pending payment first".',
      `Your answer applies to order #${p.order_id} only, at this total. Keep ${p.token} in the subject.`,
    ].join('\n');
    return { channel, address, subject: `Credit approval needed: order #${p.order_id} for ${p.chemist.name} [${p.token}]`, text };
  }

  if (n.kind === 'credit_decision_to_rep') {
    need(p.decision === 'approved' || p.decision === 'rejected', 'decision');
    need(isInt(p.order_id) && isStr(p.manager_name) && isStr(p.chemist_name) && isInt(p.order_total_paise), 'decision fields');
    const head = `Order #${p.order_id} for ${p.chemist_name} (${formatRupees(p.order_total_paise)})`;
    // The manager's note is shown for a rejection (it carries the reason); an approval reply's
    // first line ("ok", "APPROVE") stays in the audit trail only.
    const note = p.decision === 'rejected' && typeof p.note === 'string' && p.note.trim() ? ` Note from ${p.manager_name}: "${p.note.trim().slice(0, 300)}"` : '';
    const text = p.decision === 'approved'
      ? `${head} was approved by ${p.manager_name}. It will now be sent to the distributor.${note}`
      : `${head} was NOT approved by ${p.manager_name}. Nothing was sent to the distributor.${note}`;
    return { channel, address, ...(channel === 'email' ? { subject: `Order #${p.order_id}: credit ${p.decision}` } : {}), text };
  }

  if (n.kind === 'evening_summary') {
    const { subject, text } = renderEveningSummary(p);
    return { channel, address, ...(channel === 'email' ? { subject } : {}), text };
  }

  if (n.kind === 'order_status_to_rep') {
    need(p.status === 'accepted' || p.status === 'dispatched' || p.status === 'distributor_rejected', 'status');
    need(isInt(p.order_id) && isStr(p.chemist_name) && isStr(p.distributor_ref) && isInt(p.order_total_paise), 'status fields');
    const head = `Order #${p.order_id} for ${p.chemist_name} (${formatRupees(p.order_total_paise)}, distributor ref ${p.distributor_ref})`;
    const reason = typeof p.reason === 'string' && p.reason.trim() ? ` Reason given: "${p.reason.trim().slice(0, 300)}".` : '';
    const text = p.status === 'accepted' ? `${head} was accepted by the distributor.`
      : p.status === 'dispatched' ? `${head} has been dispatched.`
      : `${head} was REJECTED by the distributor.${reason} The chemist has not been charged for it.`;
    return { channel, address, ...(channel === 'email' ? { subject: `Order #${p.order_id}: ${p.status.replace('_', ' ')}` } : {}), text };
  }

  throw new SummaryDataError(`unknown kind ${String(n.kind).slice(0, 40)}`);
}

export type DispatchDeps = {
  claim: (limit: number) => Promise<ClaimedNotification[]>;
  complete: (id: number, providerRef: string) => Promise<unknown>;
  fail: (id: number, error: string) => Promise<unknown>;
  send: (m: OutgoingMessage) => Promise<{ ref: string }>;
  limit: number;
  sendTimeoutMs: number;
};

export type DispatchReport = { claimed: number; sent: number; failed: number; error?: string };

// Error text that is safe to store and log: never the raw message.
function safeError(err: unknown): string {
  const name = err instanceof Error && /^[A-Za-z]{1,40}$/.test(err.name) ? err.name : 'unknown';
  const msg = err instanceof SummaryDataError ? err.message : '';
  return msg ? `${name}: ${msg}`.slice(0, 200) : name;
}

// Sends every claimed notification once. Never throws.
export async function dispatchNotifications(d: DispatchDeps): Promise<DispatchReport> {
  const report: DispatchReport = { claimed: 0, sent: 0, failed: 0 };
  let rows: ClaimedNotification[];
  try {
    rows = await d.claim(d.limit);
    if (!Array.isArray(rows)) throw new Error('claim returned no rows');
  } catch (err) {
    return { ...report, error: `claim failed (${safeError(err)})` };
  }
  report.claimed = rows.length;
  for (const n of rows) {
    const id = Number(n.id);
    if (!Number.isSafeInteger(id) || id <= 0) { report.failed++; continue; }
    try {
      const msg = renderNotification(n);
      if (msg.channel === 'whatsapp' && typeof n.lua_user_id === 'string' && /^[A-Za-z0-9_:.-]{1,128}$/.test(n.lua_user_id)) msg.luaUserId = n.lua_user_id;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('send timeout')), d.sendTimeoutMs); });
      let sent: { ref: string };
      try {
        sent = await Promise.race([d.send(msg), timeout]);
      } finally {
        clearTimeout(timer);
      }
      await d.complete(id, typeof sent?.ref === 'string' ? sent.ref : '');
      report.sent++;
    } catch (err) {
      report.failed++;
      try { await d.fail(id, safeError(err)); } catch { /* lease expiry retries it */ }
    }
  }
  return report;
}
