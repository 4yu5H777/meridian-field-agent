// One inbound turn with media -> either the canonical order text the model
// passes to prepare_order (proceed), or a reply the rep must answer (block).
// Turns without media are returned untouched, so typed orders and typed
// "YES 4821" confirmations work exactly as before (the confirmation gate has
// already run by then: it only ever accepts a single typed text part).
//
// Every failure blocks with a useful reply and "Nothing was created": a file
// that cannot be read never reaches the model as raw media.
import {
  validateExtraction, renderCanonical, parseQuantity, renderClarification, looksLikeConfirmation, SOURCE_LABEL,
  type Extraction, type MediaSource, type Validated,
} from './canonical.ts';
import { loadMedia, MediaError, MAX_MEDIA_BYTES, type FetchBytes, type MediaPart } from './load.ts';
import { readXlsx, readCsv, rowsToExtraction, SheetError } from './spreadsheet.ts';
import { numbersIn } from '../lang.ts';
import { transcribe, extractFromTranscript, extractFromImage, extractFromPdf, type AiCall } from './reader.ts';

export type TurnPart = { type: 'text'; text: string } | MediaPart;
export type NormalizeOutcome =
  | { action: 'proceed'; modifiedMessage?: { type: 'text'; text: string }[]; log: string }
  | { action: 'block'; response: string; log: string };

export const MAX_MEDIA_PARTS = 3;
export const REPLY_TOO_MANY = `Please send at most ${MAX_MEDIA_PARTS} files, photos or voice notes in one message. Nothing was created.`;
export const REPLY_UNSUPPORTED = 'I can read orders from voice notes, photos, Excel (.xlsx or .csv) and PDF files. Please send the order in one of those, or type it. Nothing was created.';
export const REPLY_OLD_EXCEL = 'That looks like an old Excel file (.xls). Please save it as .xlsx or .csv and send it again, or type the order. Nothing was created.';
export const REPLY_TOO_LARGE = `That file is too large (the limit is ${MAX_MEDIA_BYTES / 1024 / 1024} MB). Please send a smaller file or type the order. Nothing was created.`;
export const REPLY_NO_COLUMNS = 'I could not find the product and quantity columns in that spreadsheet. Please give it a header row with "Product" and "Qty" (and "Chemist"), or type the order. Nothing was created.';
export const replyReadFailed = (label: string) => `I could not read that ${label} just now. Nothing was created. Please try again in a minute, or type the order.`;

class Refusal extends Error {
  reply: string;
  why: string;
  constructor(reply: string, why: string) { super(why); this.name = 'Refusal'; this.reply = reply; this.why = why; }
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([p, new Promise<T>((_, rej) => { timer = setTimeout(() => rej(new Error('reader timeout')), ms); })])
    .finally(() => clearTimeout(timer));
}

async function readOne(part: MediaPart, deps: { ai: AiCall; model: string; fetchBytes: FetchBytes; aiTimeoutMs: number }, captionText: string): Promise<Validated> {
  let media;
  try {
    media = await loadMedia(part, deps.fetchBytes);
  } catch (e) {
    if (e instanceof MediaError && e.reason === 'too_large') throw new Refusal(REPLY_TOO_LARGE, 'too_large');
    throw new Refusal(replyReadFailed('file'), e instanceof MediaError ? e.reason : 'load_failed');
  }
  const extra = captionText ? [captionText] : [];
  // One retry when the reader call itself fails (a transient provider error);
  // a timeout is not retried, so a voice note stays well inside the 180 s budget.
  const ai = async <T>(call: () => Promise<T>, label: string): Promise<T> => {
    for (let attempt = 1; ; attempt++) {
      try {
        return await withTimeout(call(), deps.aiTimeoutMs);
      } catch (e) {
        if (attempt >= 2 || (e instanceof Error && e.message === 'reader timeout')) throw new Refusal(replyReadFailed(label), 'reader_failed');
      }
    }
  };

  switch (media.kind) {
    case 'audio': {
      const t = await ai(() => transcribe(deps.ai, deps.model, media.bytes, media.mediaType), SOURCE_LABEL.voice);
      if (!t) throw new Refusal(replyReadFailed(SOURCE_LABEL.voice), 'no_transcript');
      if (looksLikeConfirmation(t.transcript)) return { kind: 'confirmation_in_media', source: 'voice' };
      if (t.inaudible || t.transcript.replace(/\[unclear\]/gi, '').trim().length < 3) return { kind: 'unreadable', source: 'voice' };
      const x = await ai(() => extractFromTranscript(deps.ai, deps.model, t, captionText), SOURCE_LABEL.voice);
      if (!x) throw new Refusal(replyReadFailed(SOURCE_LABEL.voice), 'no_extraction');
      // The transcript's own doubt carries into the order: a low-confidence
      // or partly unclear transcript is never passed on as if it were clear.
      // And every quantity must be one the rep actually said: a number the reader
      // produced that is not in the transcript (e.g. "Cetimer 10" x 1 from "Cetimer,
      // ten strips") is marked unsure, so the rep is asked instead.
      const said = numbersIn(t.transcript);
      const checked = Array.isArray(x.orders) ? (x.orders as { lines?: unknown }[]).map((o) => ({
        ...o,
        lines: Array.isArray(o?.lines) ? (o.lines as { quantity?: unknown }[]).map((l) => {
          const q = parseQuantity(l?.quantity);
          return q !== null && !said.has(q) ? { ...l, confidence: 0 } : l;
        }) : o?.lines,
      })) : x.orders;
      const merged: Extraction = {
        ...x,
        orders: checked,
        confidence: Math.min(typeof x.confidence === 'number' ? x.confidence : 0, t.confidence),
        unclear: [...(Array.isArray(x.unclear) ? x.unclear : []), ...(t.unclearMarks > 0 ? ['parts of the voice note'] : [])],
      };
      return validateExtraction(merged, 'voice', [...extra, t.transcript]);
    }
    case 'image': {
      const x = await ai(() => extractFromImage(deps.ai, deps.model, media.bytes, media.mediaType, captionText), SOURCE_LABEL.photo);
      return validateExtraction(x, 'photo', extra);
    }
    case 'pdf': {
      const x = await ai(() => extractFromPdf(deps.ai, deps.model, media.bytes, captionText), SOURCE_LABEL.pdf);
      return validateExtraction(x, 'pdf', extra);
    }
    case 'xlsx':
    case 'csv': {
      let x: Extraction | null;
      try {
        const rows = media.kind === 'xlsx' ? readXlsx(media.bytes) : readCsv(new TextDecoder('utf-8').decode(media.bytes));
        x = rowsToExtraction(rows);
      } catch (e) {
        if (e instanceof SheetError && e.reason === 'old_excel') throw new Refusal(REPLY_OLD_EXCEL, 'old_excel');
        if (e instanceof SheetError && e.reason === 'too_large') throw new Refusal(REPLY_TOO_LARGE, 'sheet_too_large');
        if (e instanceof SheetError && e.reason === 'empty') return { kind: 'unreadable', source: 'excel' };
        throw new Refusal(replyReadFailed(SOURCE_LABEL.excel), 'sheet_corrupt');
      }
      if (!x) throw new Refusal(REPLY_NO_COLUMNS, 'no_columns');
      return validateExtraction(x, 'excel', extra);
    }
    case 'old_excel':
      throw new Refusal(REPLY_OLD_EXCEL, 'old_excel');
    default:
      throw new Refusal(REPLY_UNSUPPORTED, 'unsupported');
  }
}

export async function normalizeTurn(input: {
  messages: readonly unknown[];
  ai: AiCall;
  model: string;
  fetchBytes: FetchBytes;
  aiTimeoutMs: number;
}): Promise<NormalizeOutcome> {
  const parts = Array.isArray(input.messages) ? input.messages as TurnPart[] : [];
  const media = parts.filter((p): p is MediaPart => !!p && (p.type === 'image' || p.type === 'file'));
  if (media.length === 0) return { action: 'proceed', log: 'no media' };
  if (media.length > MAX_MEDIA_PARTS) return { action: 'block', response: REPLY_TOO_MANY, log: 'too many media parts' };

  const texts = parts.filter((p): p is { type: 'text'; text: string } => !!p && p.type === 'text' && typeof p.text === 'string');
  const captionText = texts.map((t) => t.text).join('\n').trim().slice(0, 1000);

  const results: Validated[] = [];
  try {
    for (const part of media) results.push(await readOne(part, input, captionText));
  } catch (e) {
    if (e instanceof Refusal) return { action: 'block', response: e.reply, log: `refused (${e.why})` };
    return { action: 'block', response: replyReadFailed('file'), log: 'refused (unexpected)' };
  }

  const confirmation = results.find((r) => r.kind === 'confirmation_in_media');
  if (confirmation) return { action: 'block', response: renderClarification(confirmation as Exclude<Validated, { kind: 'ok' }>), log: `refused (confirmation in ${confirmation.source})` };
  const needs = results.filter((r): r is Exclude<Validated, { kind: 'ok' }> => r.kind !== 'ok');
  if (needs.length > 0) {
    return { action: 'block', response: needs.map(renderClarification).join('\n\n'), log: `clarify (${needs.map((r) => `${r.source}:${r.kind}`).join(', ')})` };
  }

  const blocks = results.map((r) => renderCanonical(r as Extract<Validated, { kind: 'ok' }>));
  const sources = [...new Set(results.map((r) => r.source as MediaSource))].join('+');
  return {
    action: 'proceed',
    modifiedMessage: [...(captionText ? [{ type: 'text' as const, text: captionText }] : []), { type: 'text', text: blocks.join('\n\n') }],
    log: `canonical (${sources}, ${results.reduce((n, r) => n + (r.kind === 'ok' ? r.orders.length : 0), 0)} orders)`,
  };
}
