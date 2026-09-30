// Excel (.xlsx) and CSV orders, parsed deterministically: no model reads the
// file. The first worksheet becomes rows of cell text; a header row names the
// chemist / product / quantity columns (English or Hindi headers); every other
// column, including any price, rate or total, is ignored.
//
// Untrusted input: bounded unzip (entry count, per-entry and total size, so a
// zip bomb stops early), plain-text XML scanning with no entity expansion,
// bounded rows and columns. Anything outside those bounds is refused.
// The browser build: no require('module') at load time (the Node build has
// one for worker threads, which a sandboxed runtime may not provide).
import { unzipSync, strFromU8 } from 'fflate/browser';
import type { Extraction } from './canonical.ts';

export const MAX_ROWS = 500;
export const MAX_COLS = 30;
const MAX_ENTRY_BYTES = 8 * 1024 * 1024;
const MAX_TOTAL_BYTES = 20 * 1024 * 1024;
const MAX_ENTRIES = 200;

export type SheetErrorReason = 'corrupt' | 'too_large' | 'empty' | 'old_excel';
export class SheetError extends Error {
  reason: SheetErrorReason;
  constructor(reason: SheetErrorReason) {
    super(`spreadsheet: ${reason}`);
    this.name = 'SheetError';
    this.reason = reason;
  }
}

const decodeXml = (s: string) => s
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, '\'')
  .replace(/&#(\d{1,7});/g, (_, d) => safeChar(Number(d)))
  .replace(/&#x([0-9a-f]{1,6});/gi, (_, h) => safeChar(parseInt(h, 16)))
  .replace(/&amp;/g, '&');
const safeChar = (n: number) => (n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '');

// All text runs of an <si> / <is> element, joined (rich text has several <t>).
const textRuns = (xml: string) => [...xml.matchAll(/<t(?:\s[^>]*)?>([\s\S]*?)<\/t>/g)].map((m) => decodeXml(m[1])).join('');

const colIndex = (ref: string) => {
  const letters = /^([A-Z]{1,3})/.exec(ref)?.[1] ?? '';
  let n = 0;
  for (const ch of letters) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
};

export function readXlsx(bytes: Uint8Array): string[][] {
  if (bytes.length >= 8 && bytes[0] === 0xd0 && bytes[1] === 0xcf && bytes[2] === 0x11 && bytes[3] === 0xe0) throw new SheetError('old_excel');
  let entries = 0;
  let total = 0;
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes, {
      filter: (f) => {
        entries += 1;
        total += f.originalSize;
        if (entries > MAX_ENTRIES || f.originalSize > MAX_ENTRY_BYTES || total > MAX_TOTAL_BYTES) throw new SheetError('too_large');
        return f.name === 'xl/workbook.xml' || f.name === 'xl/_rels/workbook.xml.rels'
          || f.name === 'xl/sharedStrings.xml' || /^xl\/worksheets\/sheet\d+\.xml$/.test(f.name);
      },
    });
  } catch (e) {
    if (e instanceof SheetError) throw e;
    throw new SheetError('corrupt');
  }
  const text = (name: string) => (files[name] ? strFromU8(files[name]) : '');
  const workbook = text('xl/workbook.xml');
  if (!workbook) throw new SheetError('corrupt');

  // First sheet in workbook order -> its part via the relationships file.
  const firstRid = /<sheet\b[^>]*\br:id="([^"]+)"/.exec(workbook)?.[1];
  const rels = text('xl/_rels/workbook.xml.rels');
  let target = firstRid ? new RegExp(`<Relationship\\b[^>]*Id="${firstRid.replace(/[^A-Za-z0-9]/g, '')}"[^>]*Target="([^"]+)"`).exec(rels)?.[1]
    ?? new RegExp(`<Relationship\\b[^>]*Target="([^"]+)"[^>]*Id="${firstRid.replace(/[^A-Za-z0-9]/g, '')}"`).exec(rels)?.[1] : undefined;
  if (target) target = 'xl/' + target.replace(/^\/?xl\//, '').replace(/^\//, '');
  const sheetName = target && files[target] ? target : Object.keys(files).filter((n) => n.startsWith('xl/worksheets/')).sort()[0];
  if (!sheetName) throw new SheetError('corrupt');

  const shared = [...text('xl/sharedStrings.xml').matchAll(/<si>([\s\S]*?)<\/si>/g)].map((m) => textRuns(m[1]));
  const rows: string[][] = [];
  for (const row of strFromU8(files[sheetName]).matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/g)) {
    if (rows.length >= MAX_ROWS) break;
    const cells: string[] = [];
    let next = 0;
    for (const c of row[1].matchAll(/<c\b([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
      const attrs = c[1];
      const ref = /\br="([A-Z]{1,3}\d+)"/.exec(attrs)?.[1];
      const idx = ref ? colIndex(ref) : next;
      next = idx + 1;
      if (idx < 0 || idx >= MAX_COLS) continue;
      const type = /\bt="([a-zA-Z]+)"/.exec(attrs)?.[1];
      const body = c[2] ?? '';
      const v = /<v>([\s\S]*?)<\/v>/.exec(body)?.[1];
      let value = '';
      if (type === 's') value = shared[Number(v)] ?? '';
      else if (type === 'inlineStr') value = textRuns(body);
      else if (v !== undefined) value = decodeXml(v);
      cells[idx] = value.replace(/\s+/g, ' ').trim();
    }
    rows.push(Array.from({ length: cells.length }, (_, i) => cells[i] ?? ''));
  }
  return rows;
}

// RFC 4180-ish: commas (or semicolons / tabs, detected), double-quoted fields.
export function readCsv(textIn: string): string[][] {
  const text = textIn.replace(/^﻿/, '');
  const firstLine = text.split(/\r?\n/, 1)[0] ?? '';
  const sep = [',', ';', '\t'].sort((a, b) => firstLine.split(b).length - firstLine.split(a).length)[0];
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length && rows.length < MAX_ROWS; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (ch === '"') quoted = false;
      else field += ch;
    } else if (ch === '"' && field === '') quoted = true;
    else if (ch === sep) { row.push(field.trim()); field = ''; }
    else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && text[i + 1] === '\n') i++;
      row.push(field.trim()); rows.push(row.slice(0, MAX_COLS)); row = []; field = '';
    } else field += ch;
  }
  if ((field !== '' || row.length > 0) && rows.length < MAX_ROWS) { row.push(field.trim()); rows.push(row.slice(0, MAX_COLS)); }
  return rows;
}

// Header words, compared after lower-casing and stripping punctuation.
const HEADERS = {
  chemist: ['chemist', 'chemist name', 'customer', 'customer name', 'party', 'party name', 'retailer', 'shop', 'shop name', 'store', 'outlet', 'dukaan', 'दुकान', 'केमिस्ट', 'ग्राहक', 'पार्टी'],
  product: ['product', 'product name', 'item', 'item name', 'medicine', 'sku', 'description', 'particulars', 'brand', 'dawa', 'dawai', 'दवा', 'दवाई', 'प्रोडक्ट', 'आइटम', 'माल'],
  quantity: ['qty', 'quantity', 'packs', 'no of packs', 'strips', 'boxes', 'order qty', 'order quantity', 'मात्रा', 'संख्या', 'नग'],
  unit: ['unit', 'uom', 'pack type', 'इकाई'],
} as const;
const norm = (s: string) => s.normalize('NFC').toLowerCase().replace(/[^\p{L}\p{M}\p{N} ]/gu, ' ').replace(/\s+/g, ' ').trim();
const find = (row: string[], names: readonly string[]) => row.findIndex((c) => names.includes(norm(c)));

// Rows -> Extraction, or null when no header row names product and quantity
// (the caller then says it could not find the columns; no model guesses them).
export function rowsToExtraction(rows: string[][], captionChemist = ''): Extraction | null {
  if (rows.length === 0) throw new SheetError('empty');
  for (let h = 0; h < Math.min(rows.length, 10); h++) {
    const header = rows[h];
    const col = { chemist: find(header, HEADERS.chemist), product: find(header, HEADERS.product), quantity: find(header, HEADERS.quantity), unit: find(header, HEADERS.unit) };
    if (col.product < 0 || col.quantity < 0) continue;

    // A "Chemist: Sharma Medicos" line above the header counts when there is no chemist column.
    let above = '';
    for (const r of rows.slice(0, h)) {
      const joined = r.filter(Boolean).join(' ');
      const m = /^(?:chemist|customer|party|shop|दुकान|केमिस्ट|पार्टी)\s*(?:name)?\s*[:\-]\s*(.+)$/iu.exec(joined);
      if (m) above = m[1];
    }
    const byChemist = new Map<string, { product: string; quantity: string; unit: string }[]>();
    let current = col.chemist >= 0 ? '' : (above || captionChemist);
    for (const r of rows.slice(h + 1)) {
      const product = r[col.product] ?? '';
      const qty = r[col.quantity] ?? '';
      if (col.chemist >= 0 && (r[col.chemist] ?? '').trim()) current = r[col.chemist];   // merged / blank chemist cells repeat the last one
      if (!product.trim() && !qty.trim()) continue;
      // A totals row is not an order line, wherever its label sits (its figures
      // are never used: quantities come from the lines, prices from the price list).
      if (r.some((cell) => /^(sub[\s-]*|grand\s*)?total\b|^कुल/iu.test((cell ?? '').trim()))) continue;
      const key = current.trim();
      if (!byChemist.has(key)) byChemist.set(key, []);
      byChemist.get(key)!.push({ product, quantity: qty, unit: col.unit >= 0 ? (r[col.unit] ?? '') : '' });
    }
    if (byChemist.size === 0) throw new SheetError('empty');
    return {
      readable: true,
      orders: [...byChemist.entries()].map(([chemist, lines]) => ({ chemist, lines })),
    };
  }
  return null;
}
