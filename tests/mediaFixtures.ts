// Media fixtures for the media tests: a real .xlsx built in memory, and the
// first bytes of each file type (enough for sniffing; the AI reader is stubbed).
import { zipSync, strToU8 } from 'fflate';
import type { AiCall } from '../src/lib/media/reader.ts';
import { TRANSCRIBE_SYSTEM } from '../src/lib/media/reader.ts';

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const col = (i: number) => String.fromCharCode(65 + i);

// rows of strings/numbers -> .xlsx bytes (strings as shared strings, numbers as numbers).
export function xlsx(rows: (string | number)[][], opts: { inline?: boolean } = {}): Uint8Array {
  const shared: string[] = [];
  const sheetRows = rows.map((r, ri) => `<row r="${ri + 1}">${r.map((v, ci) => {
    const ref = `${col(ci)}${ri + 1}`;
    if (typeof v === 'number') return `<c r="${ref}"><v>${v}</v></c>`;
    if (v === '') return '';
    if (opts.inline) return `<c r="${ref}" t="inlineStr"><is><t>${esc(v)}</t></is></c>`;
    shared.push(v);
    return `<c r="${ref}" t="s"><v>${shared.length - 1}</v></c>`;
  }).join('')}</row>`).join('');
  return zipSync({
    '[Content_Types].xml': strToU8('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'),
    'xl/workbook.xml': strToU8('<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Order" sheetId="1" r:id="rId1"/></sheets></workbook>'),
    'xl/_rels/workbook.xml.rels': strToU8('<Relationships><Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/></Relationships>'),
    'xl/sharedStrings.xml': strToU8(`<sst>${shared.map((s) => `<si><t>${esc(s)}</t></si>`).join('')}</sst>`),
    'xl/worksheets/sheet1.xml': strToU8(`<worksheet><sheetData>${sheetRows}</sheetData></worksheet>`),
  });
}

export const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
export const b64 = (u: Uint8Array | string) => Buffer.from(u).toString('base64');
export const PDF = new Uint8Array(Buffer.from('%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF'));
export const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
export const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46]);
export const OGG = new Uint8Array(Buffer.from('OggS\0\u0002\0\0\0\0\0\0\0\0OpusHead'));
export const OLD_XLS = new Uint8Array([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0, 0]);
export const MP4 = new Uint8Array([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6d, 0x70, 0x34, 0x32]);

export const part = {
  voice: (bytes = OGG) => ({ type: 'file' as const, data: b64(bytes), mediaType: 'audio/ogg; codecs=opus' }),
  photo: (bytes = JPEG) => ({ type: 'image' as const, image: b64(bytes), mediaType: 'image/jpeg' }),
  pdf: (bytes = PDF) => ({ type: 'file' as const, data: b64(bytes), mediaType: 'application/pdf' }),
  excel: (bytes: Uint8Array) => ({ type: 'file' as const, data: b64(bytes), mediaType: XLSX_TYPE }),
  csv: (text: string) => ({ type: 'file' as const, data: b64(text), mediaType: 'text/csv' }),
};

// A stub reader: returns the given transcript for a transcription call and the
// given extraction for an extraction call; records every call.
export function fakeAi(opts: { transcript?: unknown; extraction?: unknown; fail?: 'throw' | 'hang' | 'empty' }) {
  const calls: Parameters<AiCall>[0][] = [];
  const ai: AiCall = async (input) => {
    calls.push(input);
    if (opts.fail === 'throw') throw new Error('provider down postgresql://u:secret@h/db');
    if (opts.fail === 'hang') return await new Promise(() => {});
    if (opts.fail === 'empty') return { finishReason: 'length' };
    return { output: input.system === TRANSCRIBE_SYSTEM ? opts.transcript : opts.extraction, finishReason: 'stop' };
  };
  return { ai, calls };
}

export const noFetch = async () => { throw new Error('no network in tests'); };

// The order the integration test places through every input type, as the
// typed-order test writes it: Deepak Chauhan (REP-NOI-01), Rs 322.00 with schemes.
export const ORDER = { chemist: 'Singh Medical Agency', lines: [{ product: 'Cetimer', quantity: 10 }, { product: 'ORS orange', quantity: 6 }] };
export const extractionOf = (o = ORDER, extra: Record<string, unknown> = {}) => ({
  readable: true, confidence: 0.95, unclear: [],
  orders: [{ chemist: o.chemist, chemist_confidence: 0.95, lines: o.lines.map((l) => ({ product: l.product, quantity: String(l.quantity), unit: '', confidence: 0.95 })) }],
  ...extra,
});
