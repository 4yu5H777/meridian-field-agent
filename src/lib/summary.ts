// The canonical order summary, and the rule that the rep only ever sees it.
// Pure, so it can be unit-tested with plain Node.
//
// renderSummary() turns meridian.order_summary() output (the same JSON whether
// it came back from prepare_order or from live_order_summaries) into the text
// the rep sees. It does no arithmetic: every amount, free unit, discount,
// scheme, total, warning, code and expiry is a field the database computed.
// Anything missing or malformed throws, so a caller fails closed instead of
// showing a summary with gaps.
//
// enforceSummaryIntegrity() is the summary-integrity postprocessor's logic:
// the model's reply is replaced by the canonical summary whenever it could be
// carrying one, and by a fixed safe message whenever that cannot be done.
import { formatRupees } from './confirmation.ts';
import type { SenderContext } from './identity.ts';

export type OrderSummaryLine = {
  line_no: number; product: string; pack: string; qty: number;
  unit_price_paise: number; gross_paise: number; free_qty: number;
  discount_paise: number; line_total_paise: number; scheme: string | null;
};

export type OrderSummary = {
  order_id: number;
  status: string;
  chemist: { code: string; name: string; locality: string };
  lines: OrderSummaryLine[];
  total_paise: number;
  is_off_route: boolean;
  duplicate: { order_id: number; status: string; at_ist: string } | null;
  credit: { limit_paise: number; owed_paise: number; over_limit: boolean; manager_name: string };
  confirmation: { code: string; total_paise: number; expires_ist: string } | null;
};

export class SummaryDataError extends Error {
  constructor(what: string) {
    super(`summary data invalid: ${what}`);
    this.name = 'SummaryDataError';
  }
}

const isInt = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);
const isStr = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && v.length <= 300;
const need = (ok: boolean, what: string) => { if (!ok) throw new SummaryDataError(what); };

// Accepts only a complete, well-typed summary that is still waiting for the
// rep's YES. Nothing is defaulted or filled in.
export function checkSummary(raw: unknown): OrderSummary {
  const s = raw as OrderSummary;
  need(!!s && typeof s === 'object', 'not an object');
  need(isInt(s.order_id) && s.order_id > 0, 'order_id');
  need(s.status === 'awaiting_confirmation', 'status');
  need(!!s.chemist && isStr(s.chemist.name) && isStr(s.chemist.locality), 'chemist');
  checkLines(s.lines);
  need(isInt(s.total_paise) && s.total_paise > 0, 'total');
  need(typeof s.is_off_route === 'boolean', 'is_off_route');
  need(s.duplicate === null || (!!s.duplicate && isInt(s.duplicate.order_id) && /^[0-2][0-9]:[0-5][0-9]$/.test(s.duplicate.at_ist)), 'duplicate');
  need(!!s.credit && isInt(s.credit.limit_paise) && isInt(s.credit.owed_paise) && typeof s.credit.over_limit === 'boolean'
       && isStr(s.credit.manager_name), 'credit');
  need(!!s.confirmation && /^[0-9]{4}$/.test(s.confirmation.code) && isInt(s.confirmation.total_paise)
       && s.confirmation.total_paise === s.total_paise && /^[0-2][0-9]:[0-5][0-9]$/.test(s.confirmation.expires_ist), 'confirmation');
  return s;
}

export function checkLines(raw: unknown): OrderSummaryLine[] {
  const lines = raw as OrderSummaryLine[];
  need(Array.isArray(lines) && lines.length >= 1 && lines.length <= 50, 'lines');
  for (const l of lines) {
    need(!!l && isInt(l.line_no) && isStr(l.product) && isStr(l.pack) && isInt(l.qty) && l.qty > 0, 'line identity');
    need(isInt(l.unit_price_paise) && isInt(l.gross_paise) && isInt(l.free_qty) && isInt(l.discount_paise)
         && isInt(l.line_total_paise), 'line amounts');
    need(l.scheme === null || isStr(l.scheme), 'line scheme');
  }
  return lines;
}

// Order lines as the rep and the manager see them. Formatting only.
export function formatSummaryLines(raw: unknown): string[] {
  const out: string[] = [];
  for (const l of checkLines(raw)) {
    out.push(`${l.line_no}. ${l.product} (${l.pack}) x ${l.qty} @ ${formatRupees(l.unit_price_paise)} = ${formatRupees(l.line_total_paise)}`);
    if (l.scheme && l.free_qty > 0) out.push(`   ${l.scheme}: ${l.free_qty} free`);
    if (l.scheme && l.discount_paise > 0) {
      out.push(`   ${l.scheme}: ${formatRupees(l.gross_paise)} less ${formatRupees(l.discount_paise)}`);
    }
  }
  return out;
}

export function renderSummary(raw: unknown): string {
  const s = checkSummary(raw);
  const out: string[] = [];
  out.push(`Order #${s.order_id} for ${s.chemist.name}, ${s.chemist.locality}`);
  out.push(...formatSummaryLines(s.lines));
  out.push(`Total: ${formatRupees(s.total_paise)}`);
  if (s.is_off_route) {
    out.push(`Note: ${s.chemist.name} is not on today's route. That is allowed; it will be flagged in the evening summary.`);
  }
  if (s.credit.over_limit) {
    out.push(`Credit: this order takes ${s.chemist.name} over its limit of ${formatRupees(s.credit.limit_paise)} `
      + `(already owed ${formatRupees(s.credit.owed_paise)}). If you confirm, it goes to ${s.credit.manager_name} for approval before anything is sent.`);
  }
  if (s.duplicate) {
    out.push(`Warning: this looks like a repeat of order #${s.duplicate.order_id} placed at ${s.duplicate.at_ist} `
      + '(same chemist and items). Confirm only if you want both.');
  }
  out.push(`To confirm, reply exactly: YES ${s.confirmation!.code} (valid until ${s.confirmation!.expires_ist} IST).`);
  return out.join('\n');
}

// ---------------------------------------------------------------------------
// Integrity: what the rep actually receives.
// ---------------------------------------------------------------------------

export type LiveSummaryRow = { confirmation_id: unknown; order_id: unknown; code: unknown; delivered: unknown; summary: unknown };

export const SUMMARY_UNAVAILABLE =
  'I could not load the order summary just now. Nothing has been confirmed. Please ask me to show the order summary again.';
export const SUMMARY_NOT_VALID =
  'That order summary is not valid any more. Nothing has been confirmed. Ask me to show the current order summary.';

const DEVANAGARI_DIGITS = /[०-९]/g;
const toAsciiDigits = (t: string) => t.replace(DEVANAGARI_DIGITS, (d) => String(d.charCodeAt(0) - 0x0966));

// Standalone 4-digit numbers in a text (Devanagari digits normalised).
export function fourDigitTokens(text: string): string[] {
  return toAsciiDigits(text).match(/(?<![0-9])[0-9]{4}(?![0-9])/g) ?? [];
}

// "YES 1234" / "haan 1234" / "हाँ 1234" / "confirm 1234" anywhere in a reply.
const CONFIRM_INSTRUCTION = /(yes|haan|han|confirm|हाँ|हां)[\s:#"'*-]{0,4}[0-9]{4}(?![0-9])/iu;
export function hasConfirmInstruction(text: string): boolean {
  return CONFIRM_INSTRUCTION.test(toAsciiDigits(text));
}

// Could this reply be carrying order data? Used only when the database cannot
// be reached: then anything that might be a summary is withheld.
export function mightCarryOrderData(text: string): boolean {
  return fourDigitTokens(text).length > 0 || hasConfirmInstruction(text) || /₹|\brs\.?\s*[0-9]/iu.test(text);
}

export type IntegrityDb = {
  liveSummaries: (channel: 'whatsapp' | 'email', contacts: string[]) => Promise<LiveSummaryRow[]>;
  markDelivered: (channel: 'whatsapp' | 'email', contacts: string[], confirmationIds: number[]) => Promise<number>;
};

export type IntegrityOutcome = { text: string; log: string };

class IntegrityTimeout extends Error {
  constructor() { super('database timeout'); this.name = 'IntegrityTimeout'; }
}

async function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new IntegrityTimeout()), ms); });
  try {
    return await Promise.race([p, timeout]);
  } finally {
    clearTimeout(timer);
  }
}

// Never throws. Every path returns the text to send.
export async function enforceSummaryIntegrity(input: {
  response: string;
  sender: SenderContext;
  db: IntegrityDb;
  timeoutMs: number;
}): Promise<IntegrityOutcome> {
  const response = typeof input.response === 'string' ? input.response : '';

  // No verified rep on this turn: nothing live can belong to it, so a reply
  // that tells someone to confirm a code is not trustworthy.
  if (!input.sender.ok) {
    return hasConfirmInstruction(response)
      ? { text: SUMMARY_NOT_VALID, log: `no sender (${input.sender.reason}); confirm instruction withheld` }
      : { text: response, log: `no sender (${input.sender.reason}); pass` };
  }
  const { channel, contacts } = input.sender;

  let rows: LiveSummaryRow[];
  try {
    rows = await withTimeout(input.db.liveSummaries(channel, contacts), input.timeoutMs);
    if (!Array.isArray(rows)) throw new SummaryDataError('rows');
  } catch (err) {
    const why = err instanceof IntegrityTimeout ? 'database timeout' : 'database error';
    return mightCarryOrderData(response)
      ? { text: SUMMARY_UNAVAILABLE, log: `${why}; reply withheld` }
      : { text: response, log: `${why}; reply has no order data; pass` };
  }

  try {
    // 1. A summary the rep has not been shown yet: this reply IS that summary.
    const undelivered = rows.filter((r) => r.delivered === false);
    if (undelivered.length > 0) {
      const text = undelivered.map((r) => renderSummary(r.summary)).join('\n\n');
      const ids = undelivered.map((r) => Number(r.confirmation_id)).filter((n) => Number.isSafeInteger(n) && n > 0);
      let marked = 'marked';
      try {
        await withTimeout(input.db.markDelivered(channel, contacts, ids), input.timeoutMs);
      } catch {
        marked = 'not marked (will be sent again next turn)';
      }
      return { text, log: `replaced with ${undelivered.length} undelivered summary(ies); ${marked}` };
    }

    // 2. The reply mentions one of this rep's live codes: show that summary, exactly.
    const tokens = new Set(fourDigitTokens(response));
    const mentioned = rows.filter((r) => typeof r.code === 'string' && tokens.has(r.code));
    if (mentioned.length > 0) {
      return { text: mentioned.map((r) => renderSummary(r.summary)).join('\n\n'),
               log: `replaced: reply mentioned ${mentioned.length} live code(s)` };
    }

    // 3. A confirm instruction with a code that is not live for this rep.
    if (hasConfirmInstruction(response)) {
      return { text: SUMMARY_NOT_VALID, log: 'confirm instruction with no live code; withheld' };
    }
    return { text: response, log: 'pass' };
  } catch {
    // Malformed summary data: never show a summary with gaps.
    return { text: SUMMARY_UNAVAILABLE, log: 'summary data invalid; reply withheld' };
  }
}
