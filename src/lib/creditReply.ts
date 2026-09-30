// A manager's reply to a credit approval email. Pure, so it can be unit-tested.
//
// Deterministic only: find the request token (subject first), read APPROVE or
// REJECT from the first line, and hand the sender's platform contacts to the
// database. Who is replying is never read from the email text; whether they
// may decide, and on which order, is decided by meridian.decide_credit_by_reply
// (manager on record, request still pending, bound to one order and total).
import { contactsFor, type InvokedState, type LuaProfile, type GateMessage } from './confirmation.ts';

const TOKEN_RE = /\bCR-[0-9A-F]{8}\b/gi;
export function findTokens(text: string): string[] {
  return [...new Set((text.match(TOKEN_RE) ?? []).map((t) => t.toUpperCase()))];
}

const APPROVE = new Set(['approve', 'approved', 'yes', 'ok', 'okay', 'haan', 'han']);
const REJECT = new Set(['reject', 'rejected', 'decline', 'declined', 'nahi', 'nahin']);

// First non-empty line: its first word decides. "no" counts only on its own or
// followed by punctuation ("No." / "No, collect first"), so "no problem" is not
// a rejection. A line that is neither is not a decision.
export function parseDecision(body: string): { decision: 'approved' | 'rejected'; note: string } | null {
  const first = body.split(/\r?\n/).map((l) => l.trim()).find((l) => l !== '' && !l.startsWith('>'));
  if (!first) return null;
  const m = /^([A-Za-z]+)(?=$|[\s.,:;!])(.*)$/.exec(first);   // a whole word: "approve-ish" is not "approve"
  if (!m) return null;
  const word = m[1].toLowerCase();
  const rest = m[2].replace(/^[\s.,:;!-]+/, '').trim().slice(0, 300);
  if (APPROVE.has(word)) return { decision: 'approved', note: first.slice(0, 300) };
  if (REJECT.has(word)) return { decision: 'rejected', note: rest || first.slice(0, 300) };
  if (word === 'no' && /^(\s*$|\s*[.,:;!-])/.test(m[2])) return { decision: 'rejected', note: rest || first.slice(0, 300) };
  return null;
}

export const REPLY_USE_EMAIL = 'Credit approvals are decided by replying to the approval email.';
export const REPLY_NOT_YOURS = 'This request can only be decided by the area manager it was sent to.';
export const REPLY_ONE_AT_A_TIME = 'Please reply to one approval email at a time, keeping its CR- reference in the subject.';
export const REPLY_HOW = 'Please reply with APPROVE or REJECT as the first line, keeping the CR- reference in the subject.';
export const REPLY_ERROR = 'I could not record that decision just now. Nothing was changed. Please reply again in a minute.';

export function replyForDecision(result: string, token: string): string {
  switch (result) {
    case 'approved': return `Approved (${token}). The order will be sent to the distributor and the rep has been told.`;
    case 'rejected': return `Rejected (${token}). Nothing will be sent to the distributor and the rep has been told.`;
    case 'already_decided': return `${token} was already decided or is no longer waiting. Nothing was changed.`;
    case 'not_found': return `No approval request matches ${token}.`;
    case 'not_authorized': return REPLY_NOT_YOURS;
    case 'bad_token':
    case 'bad_decision': return REPLY_HOW;
    default: return REPLY_ERROR;
  }
}

export type CreditReplyOutcome =
  | { action: 'proceed' }
  | { action: 'block'; response: string; log: string; decided: boolean };

export async function handleCreditReply(input: {
  messages: readonly GateMessage[];
  subject: string | undefined;
  channel: string;
  requestChannel: string | undefined;
  invoked: InvokedState;
  profile: LuaProfile | null | undefined;
  decide: (contacts: string[], token: string, decision: 'approved' | 'rejected', note: string) => Promise<string>;
  timeoutMs: number;
}): Promise<CreditReplyOutcome> {
  const body = (Array.isArray(input.messages) ? input.messages : [])
    .filter((m) => m && m.type === 'text' && typeof m.text === 'string')
    .map((m) => (m as { text: string }).text).join('\n');
  const subject = typeof input.subject === 'string' ? input.subject : '';
  const fromSubject = findTokens(subject);
  const tokens = fromSubject.length > 0 ? fromSubject : findTokens(body);
  if (tokens.length === 0) return { action: 'proceed' };           // not an approval reply

  // From here on the turn is about an approval and never reaches the model.
  if (input.invoked !== 'no') return { action: 'block', response: REPLY_USE_EMAIL, log: 'invoked', decided: false };
  if (input.channel !== 'email' || input.requestChannel !== 'email') {
    return { action: 'block', response: REPLY_USE_EMAIL, log: `channel ${input.channel}`, decided: false };
  }
  if (tokens.length > 1) return { action: 'block', response: REPLY_ONE_AT_A_TIME, log: 'several tokens', decided: false };
  const token = tokens[0];
  const parsed = parseDecision(body);
  if (!parsed) return { action: 'block', response: REPLY_HOW, log: 'no decision word', decided: false };

  const contacts = contactsFor('email', input.profile);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), input.timeoutMs); });
  try {
    const result = await Promise.race([input.decide(contacts, token, parsed.decision, parsed.note), timeout]);
    const r = typeof result === 'string' && /^[a-z_]{1,30}$/.test(result) ? result : 'unexpected';
    return { action: 'block', response: replyForDecision(r, token), log: `${token} ${parsed.decision}: ${r}`,
             decided: r === 'approved' || r === 'rejected' };
  } catch {
    return { action: 'block', response: REPLY_ERROR, log: `${token}: database call failed`, decided: false };
  } finally {
    clearTimeout(timer);
  }
}
