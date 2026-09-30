// Pure logic for the confirmation gate (src/preprocessors/ConfirmationGate.ts).
// No lua-cli or database imports, so it can be unit-tested with plain Node:
//   node --test tests/confirmation.test.ts
//
// The gate decides ONLY whether a turn is an explicit typed confirmation
// ("YES 4821") and, if so, which verified contacts to hand to the database.
// Whether the code is right, unexpired, unused, for this rep and for an
// unchanged order is decided by meridian.confirm_order_by_code, never here.

// Structural copies of the lua-cli types this module needs, so it stays
// importable without the SDK.
export type GateMessage =
  | { type: 'text'; text: string }
  | { type: 'image'; image: string; mediaType: string }
  | { type: 'file'; data: string; mediaType: string };

export type LuaProfile = {
  mobileNumbers?: unknown;
  emailAddresses?: unknown;
};

export type ConfirmChannel = 'whatsapp' | 'email';

// Words accepted in front of the code. Both spellings of हाँ (chandrabindu
// U+0901 and anusvara U+0902) are listed because they are different characters.
// Longest first so alternation prefers them; matching is anchored either way.
const CONFIRM_WORDS = [
  'जी हाँ', 'जी हां', 'confirm', 'haan', 'हाँ', 'हां', 'yes', 'han', 'haa', 'हा', 'ha',
];

// The whole (normalised) text must be: word, optional separator, exactly 4 digits.
const CONFIRM_RE = new RegExp(`^(?:${CONFIRM_WORDS.join('|')})[\\s:#-]*([0-9]{4})$`, 'u');

const DEVANAGARI_DIGITS = /[०-९]/g;

// NFC, Devanagari digits to ASCII, whitespace collapsed, Latin lower-cased,
// trailing full stops / exclamation marks / danda dropped.
export function normalizeText(text: string): string {
  return text
    .normalize('NFC')
    .replace(DEVANAGARI_DIGITS, (d) => String(d.charCodeAt(0) - 0x0966))
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase()
    .replace(/[.!।]+$/u, '')
    .trim();
}

// The 4-digit code if the text is exactly a confirmation, otherwise null.
export function parseConfirmationText(text: string): string | null {
  const m = CONFIRM_RE.exec(normalizeText(text));
  return m ? m[1] : null;
}

// The text that may carry a confirmation, or null when the turn cannot be one.
// Exactly ONE part, and it must be typed text: a voice note, an image (even
// with a "YES 4821" caption), a file, or several batched messages never qualify.
// Email: only the first non-empty line is considered (replies can carry quoted
// history below it); every other channel: the whole text.
export function confirmationCandidate(messages: readonly GateMessage[], channel: string): string | null {
  if (!Array.isArray(messages) || messages.length !== 1) return null;
  const only = messages[0];
  if (!only || only.type !== 'text' || typeof only.text !== 'string') return null;
  if (channel === 'email') {
    const first = only.text.split(/\r?\n/).find((line: string) => line.trim() !== '');
    return first ?? null;
  }
  return only.text;
}

export type InvokedState = 'no' | 'yes' | 'unknown';

export type GateDecision =
  | { action: 'proceed' }                                        // not a confirmation: the model handles it
  | { action: 'reject'; reason: 'wrong_channel' | 'invoked' | 'channel_mismatch' }
  | { action: 'confirm'; code: string; channel: ConfirmChannel };

// channel         the channel argument the preprocessor hook received
// requestChannel  Lua.request.channel (undefined when unavailable)
// invoked         whether Lua.request says a turn was started by code
export function decide(input: {
  messages: readonly GateMessage[];
  channel: string;
  requestChannel: string | undefined;
  invoked: InvokedState;
}): GateDecision {
  const candidate = confirmationCandidate(input.messages, input.channel);
  const code = candidate === null ? null : parseConfirmationText(candidate);
  if (code === null) return { action: 'proceed' };

  // From here on the turn IS a confirmation attempt and never reaches the model.
  if (input.invoked !== 'no') return { action: 'reject', reason: 'invoked' };
  if (input.channel !== 'whatsapp' && input.channel !== 'email') return { action: 'reject', reason: 'wrong_channel' };
  if (input.requestChannel !== input.channel) return { action: 'reject', reason: 'channel_mismatch' };
  return { action: 'confirm', code, channel: input.channel };
}

// The sender's contacts for this channel, taken ONLY from the platform's
// read-only profile. The database normalises them and requires that they
// resolve to exactly one active rep. Bounded so a malformed profile cannot
// produce an oversized query.
export function contactsFor(channel: ConfirmChannel, profile: LuaProfile | null | undefined): string[] {
  const raw = channel === 'whatsapp' ? profile?.mobileNumbers : profile?.emailAddresses;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((v): v is string => typeof v === 'string')
    .map((v) => v.trim())
    .filter((v) => v !== '' && v.length <= 320)
    .slice(0, 20);
}

// Paise (bigint from the database, arrives as a string) -> "₹1,23,456.50".
// Integer arithmetic only; Indian digit grouping.
export function formatRupees(paise: string | number | bigint | null | undefined): string {
  if (paise === null || paise === undefined || paise === '') return '';
  let p: bigint;
  try {
    p = BigInt(paise);
  } catch {
    return '';
  }
  const neg = p < 0n;
  if (neg) p = -p;
  const whole = (p / 100n).toString();
  const frac = (p % 100n).toString().padStart(2, '0');
  const last3 = whole.slice(-3);
  const rest = whole.slice(0, -3);
  const grouped = rest ? `${rest.replace(/\B(?=(\d{2})+(?!\d))/g, ',')},${last3}` : last3;
  return `${neg ? '-' : ''}₹${grouped}.${frac}`;
}

export type DbConfirmResult = {
  result?: unknown;
  order_id?: unknown;
  total_paise?: unknown;
};

// Fixed replies. Built only from the result code, the order id and the total:
// never contacts, credentials or database error text.
export const REPLY_ERROR =
  'I could not process that confirmation right now. Nothing was confirmed. Please send it again in a minute.';
export const REPLY_WRONG_CHANNEL =
  'Orders can only be confirmed from your registered WhatsApp number (or email) by replying YES and the 4-digit code on the summary.';
export const REPLY_NOT_AVAILABLE = 'Sorry, I cannot help with that.';

export function replyForRejection(reason: 'wrong_channel' | 'invoked' | 'channel_mismatch'): string {
  return reason === 'wrong_channel' ? REPLY_WRONG_CHANNEL : REPLY_ERROR;
}

export type GateOutcome =
  | { action: 'proceed' }
  | { action: 'block'; response: string; log: string };

// One whole turn of the gate. The database call is passed in, so the fail-closed
// paths (throw, timeout, no row) are unit-testable. Once a turn is a
// confirmation attempt, every path returns 'block': nothing falls through to
// the model. `log` is for the platform log only; it never carries contacts,
// credentials or raw error text.
export async function handleTurn(input: {
  messages: readonly GateMessage[];
  channel: string;
  requestChannel: string | undefined;
  invoked: InvokedState;
  profile: LuaProfile | null | undefined;
  confirm: (channel: ConfirmChannel, contacts: string[], code: string) => Promise<DbConfirmResult | null>;
  timeoutMs: number;
}): Promise<GateOutcome> {
  const decision = decide(input);
  if (decision.action === 'proceed') return { action: 'proceed' };
  if (decision.action === 'reject') {
    return { action: 'block', response: replyForRejection(decision.reason), log: `rejected (${decision.reason})` };
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new GateTimeout()), input.timeoutMs);
  });
  try {
    const contacts = contactsFor(decision.channel, input.profile);
    const row = await Promise.race([input.confirm(decision.channel, contacts, decision.code), timeout]);
    const result = typeof row?.result === 'string' && /^[a-z_]{1,40}$/.test(row.result) ? row.result : 'no_result';
    const orderId = row?.order_id !== undefined && /^[0-9]{1,19}$/.test(String(row?.order_id)) ? ` order ${row?.order_id}` : '';
    return { action: 'block', response: replyForResult(row), log: `${result}${orderId}` };
  } catch (err) {
    return { action: 'block', response: REPLY_ERROR, log: `database call failed (${describeError(err)})` };
  } finally {
    clearTimeout(timer);
  }
}

export class GateTimeout extends Error {
  constructor() {
    super('database timeout');
    this.name = 'GateTimeout';
  }
}

// Safe description of a failure for the log: never the raw message, which a
// driver error could use to echo the connection string. Our own fixed
// messages, or the error class plus a SQLSTATE-shaped code.
export function describeError(err: unknown): string {
  if (err instanceof GateTimeout) return 'database timeout';
  if (err instanceof Error && err.message === 'SYSTEM_DATABASE_URL is not set') return err.message;
  const name = err instanceof Error && /^[A-Za-z]{1,40}$/.test(err.name) ? err.name : 'unknown';
  const code = (err as { code?: unknown } | null)?.code;
  return typeof code === 'string' && /^[0-9A-Z]{5}$/.test(code) ? `${name} ${code}` : name;
}

export function replyForResult(row: DbConfirmResult | null | undefined): string {
  const result = typeof row?.result === 'string' ? row.result : '';
  const orderId = row?.order_id !== undefined && row?.order_id !== null && /^[0-9]+$/.test(String(row.order_id))
    ? String(row.order_id) : '';
  const total = formatRupees(row?.total_paise as string | undefined);
  switch (result) {
    case 'confirmed':
      return `✅ Order #${orderId} confirmed by you. Total ${total}.`;
    case 'awaiting_credit_approval':
      return `Order #${orderId} confirmed by you. Total ${total}. It is over the chemist's credit limit, so it has gone to your area manager for approval. You will hear the outcome here.`;
    case 'wrong_code':
    case 'invalid_code':
      return 'That code does not match a summary waiting for your confirmation. Please check the code on the latest summary.';
    case 'expired':
    case 'locked':
      return 'That code can no longer be used. Ask me to show the order summary again for a new code.';
    case 'superseded':
    case 'summary_changed':
      return 'The order changed since that summary. Please review the latest summary and reply with its code.';
    case 'already_used':
    case 'order_not_awaiting':
      return 'That order is not waiting for confirmation.';
    case 'unknown_sender':
    case 'ambiguous_sender':
    case 'not_a_rep':
      return REPLY_NOT_AVAILABLE;
    default:
      return REPLY_ERROR;   // anything unexpected fails closed
  }
}
