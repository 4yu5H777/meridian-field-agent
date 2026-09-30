// Order intake: from what the model extracted (chemist text, product text,
// quantities) to a draft order waiting for the rep's "YES <code>".
// Pure, so it can be unit-tested with plain Node; the database is passed in.
//
// The model's only job is extraction and, after a clarification, passing the
// rep's choice back. Everything else is deterministic:
//   identity        platform profile -> meridian.identify_sender
//   chemist/product meridian.match_chemist / match_product, classified by the
//                   thresholds below (ask rather than guess)
//   quantities      whole packs, 1..100000
//   prices, schemes, totals, duplicate, off-route, credit preview, code
//                   meridian.prepare_order (one atomic call) + order_summary()
import type { SenderContext } from './identity.ts';
import { renderSummary } from './summary.ts';
import { nameVariants } from './lang.ts';

export type Candidate = { id: number; name: string; detail: string; score: number; isRepAlias: boolean };

export type Classified =
  | { kind: 'resolved'; id: number; name: string; detail: string }
  | { kind: 'ambiguous'; candidates: Candidate[] }
  | { kind: 'not_found' };

// Thresholds, calibrated on the seed data (pg_trgm similarity):
//   exact name/alias = 1.0; "Singh Medicals" 0.81; "ORS" 0.44 vs 0.40;
//   another rep's chemist can still score 0.36 against one of yours.
export const EXACT = 1.0;
export const CONFIDENT = 0.8;
export const CLEAR_LEAD = 0.3;
export const FLOOR = 0.4;
export const SHORTLIST_MIN = 0.3;
export const SHORTLIST_MAX = 5;

export function classifyMatches(raw: readonly Candidate[]): Classified {
  const cands = [...raw].sort((a, b) => b.score - a.score || Number(b.isRepAlias) - Number(a.isRepAlias));
  const exact = cands.filter((c) => c.score >= EXACT);
  if (exact.length === 1) return { kind: 'resolved', id: exact[0].id, name: exact[0].name, detail: exact[0].detail };
  if (exact.length > 1) {
    const mine = exact.filter((c) => c.isRepAlias);
    if (mine.length === 1) return { kind: 'resolved', id: mine[0].id, name: mine[0].name, detail: mine[0].detail };
    return { kind: 'ambiguous', candidates: exact.slice(0, SHORTLIST_MAX) };
  }
  const top = cands[0];
  if (!top || top.score < FLOOR) return { kind: 'not_found' };
  const second = cands[1];
  if (top.score >= CONFIDENT && (!second || top.score - second.score >= CLEAR_LEAD)) {
    return { kind: 'resolved', id: top.id, name: top.name, detail: top.detail };
  }
  return { kind: 'ambiguous', candidates: cands.filter((c) => c.score >= SHORTLIST_MIN).slice(0, SHORTLIST_MAX) };
}

export const MAX_QTY = 100000;
export const MAX_LINES = 100;          // matches prepare_order's guard; a large PO can have 60+ lines
export function validQuantity(q: unknown): q is number {
  return typeof q === 'number' && Number.isInteger(q) && q >= 1 && q <= MAX_QTY;
}

export type IntakeInput = {
  chemist_text?: string;
  chemist_id?: number;
  lines: { product_text?: string; product_id?: number; quantity: number }[];
  source?: string;               // where the order came from; a label for the record only
};

// orders.input_type. Anything else is recorded as text; the label grants nothing.
export const INPUT_TYPES = ['text', 'voice', 'photo', 'excel', 'pdf'] as const;
export type InputType = typeof INPUT_TYPES[number];
export const inputTypeOf = (s: unknown): InputType => (INPUT_TYPES.includes(s as InputType) ? s as InputType : 'text');

export type Question = {
  about: 'chemist' | 'line';
  line?: number;                 // 1-based, for 'line'
  text?: string;                 // what the rep wrote
  problem: 'not_found' | 'ambiguous' | 'missing' | 'not_yours' | 'inactive_product' | 'invalid_quantity';
  options?: { id: number; label: string }[];
};

export type IntakeResult =
  | { status: 'refused'; message: string }
  | { status: 'needs_clarification'; questions: Question[]; message: string }
  | { status: 'ready'; order_id: number; confirmation_code: string; summary_text: string;
      superseded_order_ids: number[]; message: string }
  | { status: 'error'; message: string };

export type IntakeDb = {
  identify: (channel: 'whatsapp' | 'email', contacts: string[]) => Promise<{ result: string; user_id: number | null; role: string | null }>;
  matchChemist: (repId: number, text: string) => Promise<Candidate[]>;
  matchProduct: (repId: number, text: string) => Promise<Candidate[]>;
  repChemist: (repId: number, chemistId: number) => Promise<{ id: number; name: string; detail: string } | null>;
  activeProduct: (productId: number) => Promise<{ id: number; name: string; detail: string } | null>;
  prepareOrder: (channel: 'whatsapp' | 'email', contacts: string[], chemistId: number,
                 lines: { product_id: number; qty: number; raw_text: string }[], sourceRef: string, inputType?: InputType, chemistText?: string) => Promise<unknown>;
};

export const MSG_REFUSED = 'Sorry, I cannot help with that.';
export const MSG_ERROR = 'I could not prepare that order just now. Nothing was created. Please try again in a minute.';
const MSG_CLARIFY = 'Some details need the rep\'s answer before the order can be prepared. Ask the rep, then call prepare_order again with the chosen id or clearer text.';
const MSG_READY = 'Show the rep summary_text exactly as given. Do not restate, recalculate or summarise any amount. The rep confirms by typing the YES line.';

const cleanText = (t: unknown) => (typeof t === 'string' ? t.replace(/\s+/g, ' ').trim().slice(0, 200) : '');
const options = (cs: Candidate[]) => cs.map((c) => ({ id: c.id, label: `${c.name} (${c.detail})` }));

// Hindi / English / mixed names: each spelling from nameVariants() (as written,
// without filler and pack words, transliterated) is looked up with the same
// matcher; each candidate keeps its best score. classifyMatches() and its
// thresholds then decide exactly as before, so an unsure match is still asked.
async function lookupVariants(lookup: (repId: number, text: string) => Promise<Candidate[]>, repId: number, text: string): Promise<Candidate[]> {
  const best = new Map<number, Candidate>();
  for (const v of nameVariants(text)) {
    for (const c of await lookup(repId, v)) {
      const prev = best.get(c.id);
      if (!prev || c.score > prev.score || (c.score === prev.score && c.isRepAlias && !prev.isRepAlias)) best.set(c.id, c);
    }
  }
  return [...best.values()];
}

export async function runIntake(input: IntakeInput, sender: SenderContext, db: IntakeDb, sourceRef: string): Promise<IntakeResult> {
  if (!sender.ok) return { status: 'refused', message: MSG_REFUSED };
  try {
    const who = await db.identify(sender.channel, sender.contacts);
    if (who.result !== 'ok' || who.role !== 'rep' || typeof who.user_id !== 'number') {
      return { status: 'refused', message: MSG_REFUSED };
    }
    const repId = who.user_id;
    const questions: Question[] = [];

    // Chemist: an id the model chose from earlier options, or the rep's words.
    let chemistId: number | null = null;
    const chemText = cleanText(input?.chemist_text);
    if (Number.isSafeInteger(input?.chemist_id) && (input.chemist_id as number) > 0) {
      const c = await db.repChemist(repId, input.chemist_id as number);
      if (c) chemistId = c.id;
      else questions.push({ about: 'chemist', problem: 'not_yours' });
    } else if (chemText) {
      const m = classifyMatches(await lookupVariants(db.matchChemist, repId, chemText));
      if (m.kind === 'resolved') chemistId = m.id;
      else questions.push({ about: 'chemist', text: chemText, problem: m.kind, ...(m.kind === 'ambiguous' ? { options: options(m.candidates) } : {}) });
    } else {
      questions.push({ about: 'chemist', problem: 'missing' });
    }

    // Lines.
    const lines: { product_id: number; qty: number; raw_text: string }[] = [];
    const inLines = Array.isArray(input?.lines) ? input.lines.slice(0, MAX_LINES) : [];
    if (inLines.length === 0) questions.push({ about: 'line', problem: 'missing' });
    for (const [i, line] of inLines.entries()) {
      const n = i + 1;
      const text = cleanText(line?.product_text);
      let productId: number | null = null;
      if (Number.isSafeInteger(line?.product_id) && (line.product_id as number) > 0) {
        const p = await db.activeProduct(line.product_id as number);
        if (p) productId = p.id;
        else questions.push({ about: 'line', line: n, problem: 'inactive_product' });
      } else if (text) {
        const m = classifyMatches(await lookupVariants(db.matchProduct, repId, text));
        if (m.kind === 'resolved') productId = m.id;
        else questions.push({ about: 'line', line: n, text, problem: m.kind, ...(m.kind === 'ambiguous' ? { options: options(m.candidates) } : {}) });
      } else {
        questions.push({ about: 'line', line: n, problem: 'missing' });
      }
      if (!validQuantity(line?.quantity)) {
        questions.push({ about: 'line', line: n, text: text || undefined, problem: 'invalid_quantity' });
      }
      if (productId !== null && validQuantity(line?.quantity)) {
        lines.push({ product_id: productId, qty: line.quantity, raw_text: text });
      }
    }

    if (questions.length > 0 || chemistId === null) {
      return { status: 'needs_clarification', questions, message: MSG_CLARIFY };
    }

    // The rep's own words go with the order: once they confirm it, the database
    // learns them as this rep's aliases (schema section 18). raw_text per line, chemText here.
    const res = await db.prepareOrder(sender.channel, sender.contacts, chemistId, lines, sourceRef, inputTypeOf(input?.source), chemText) as
      { order_id?: unknown; superseded_order_ids?: unknown; summary?: unknown };
    const summaryText = renderSummary(res?.summary);           // throws on anything incomplete
    const summary = res.summary as { confirmation: { code: string } };
    return {
      status: 'ready',
      order_id: Number(res.order_id),
      confirmation_code: summary.confirmation.code,
      summary_text: summaryText,
      superseded_order_ids: Array.isArray(res.superseded_order_ids) ? res.superseded_order_ids.map(Number) : [],
      message: MSG_READY,
    };
  } catch {
    return { status: 'error', message: MSG_ERROR };
  }
}
