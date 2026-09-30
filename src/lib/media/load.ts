// Getting a media part's bytes and deciding what it is. The part's declared
// mediaType is only a hint: the file's first bytes decide, so a PDF labelled
// as a photo is read as a PDF and an executable labelled as a PDF is refused.
// Bounded: https URLs only, one size cap, a timeout (the fetch is injected).

export type MediaKind = 'audio' | 'image' | 'pdf' | 'xlsx' | 'csv' | 'old_excel' | 'unsupported';
export type LoadedMedia = { kind: MediaKind; bytes: Uint8Array; mediaType: string };
export type MediaPart = { type: 'image'; image: unknown; mediaType?: unknown } | { type: 'file'; data: unknown; mediaType?: unknown };

export const MAX_MEDIA_BYTES = 10 * 1024 * 1024;

export type MediaErrorReason = 'too_large' | 'fetch_failed' | 'bad_source' | 'empty';
export class MediaError extends Error {
  reason: MediaErrorReason;
  constructor(reason: MediaErrorReason) {
    super(`media: ${reason}`);
    this.name = 'MediaError';
    this.reason = reason;
  }
}

export type FetchBytes = (url: string, maxBytes: number) => Promise<Uint8Array>;

function fromBase64(s: string): Uint8Array {
  const clean = s.replace(/\s+/g, '');
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(clean) || clean.length === 0) throw new MediaError('bad_source');
  if (Math.floor(clean.length * 3 / 4) > MAX_MEDIA_BYTES) throw new MediaError('too_large');
  return new Uint8Array(Buffer.from(clean.replace(/-/g, '+').replace(/_/g, '/'), 'base64'));
}

export async function mediaBytes(source: unknown, fetchBytes: FetchBytes): Promise<{ bytes: Uint8Array; declared: string | null }> {
  if (source instanceof Uint8Array) {
    if (source.length > MAX_MEDIA_BYTES) throw new MediaError('too_large');
    return { bytes: source, declared: null };
  }
  if (typeof source !== 'string' || source.length === 0) throw new MediaError('bad_source');
  const dataUri = /^data:([\w.+/-]{1,100})?(?:;[\w=.-]+)*;base64,/i.exec(source);
  if (dataUri) return { bytes: fromBase64(source.slice(dataUri[0].length)), declared: dataUri[1]?.toLowerCase() ?? null };
  if (/^https:\/\//i.test(source)) {
    let bytes: Uint8Array;
    try {
      bytes = await fetchBytes(source, MAX_MEDIA_BYTES);
    } catch (e) {
      throw e instanceof MediaError ? e : new MediaError('fetch_failed');
    }
    if (bytes.length > MAX_MEDIA_BYTES) throw new MediaError('too_large');
    return { bytes, declared: null };
  }
  if (/^[a-z]+:/i.test(source)) throw new MediaError('bad_source');   // http:, file:, ftp: ... never fetched
  return { bytes: fromBase64(source), declared: null };
}

const starts = (b: Uint8Array, sig: number[], at = 0) => sig.every((x, i) => b[at + i] === x);
const ascii = (b: Uint8Array, from: number, to: number) => String.fromCharCode(...b.subarray(from, to));

// Kind from the bytes, with the declared type used only to tell CSV and
// .xlsx from other text / zip files.
export function sniff(bytes: Uint8Array, declared: string): MediaKind {
  const d = declared.toLowerCase();
  if (bytes.length < 4) return 'unsupported';
  if (ascii(bytes, 0, 5) === '%PDF-') return 'pdf';
  if (starts(bytes, [0xff, 0xd8, 0xff]) || starts(bytes, [0x89, 0x50, 0x4e, 0x47])) return 'image';
  if (ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP') return 'image';
  if (ascii(bytes, 4, 8) === 'ftyp') {
    const brand = ascii(bytes, 8, 12);
    if (/^(heic|heix|mif1|msf1)$/.test(brand)) return 'image';
    if (/^(M4A |M4B |mp42|isom|3gp)/.test(brand) && d.startsWith('audio/')) return 'audio';
    return 'unsupported';                                             // video and the rest
  }
  if (ascii(bytes, 0, 4) === 'OggS' || ascii(bytes, 0, 3) === 'ID3' || ascii(bytes, 0, 4) === 'fLaC'
      || (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0 && d.startsWith('audio/'))
      || (ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WAVE')
      || starts(bytes, [0x1a, 0x45, 0xdf, 0xa3]) && d.startsWith('audio/')) return 'audio';
  if (starts(bytes, [0xd0, 0xcf, 0x11, 0xe0])) return 'old_excel';
  if (starts(bytes, [0x50, 0x4b, 0x03, 0x04])) {
    return d.includes('spreadsheetml') || d === 'application/octet-stream' || d === '' ? 'xlsx' : 'unsupported';
  }
  if (d === 'text/csv' || d === 'application/csv' || d === 'text/comma-separated-values' || (d === 'application/vnd.ms-excel' && looksLikeText(bytes))) {
    return looksLikeText(bytes) ? 'csv' : 'unsupported';
  }
  return 'unsupported';
}

function looksLikeText(b: Uint8Array): boolean {
  const n = Math.min(b.length, 4096);
  for (let i = 0; i < n; i++) if (b[i] === 0) return false;
  try { new TextDecoder('utf-8', { fatal: true }).decode(b.subarray(0, n)); return true; } catch { return n === 4096; }
}

export async function loadMedia(part: MediaPart, fetchBytes: FetchBytes): Promise<LoadedMedia> {
  const src = part.type === 'image' ? part.image : part.data;
  const { bytes, declared } = await mediaBytes(src, fetchBytes);
  if (bytes.length === 0) throw new MediaError('empty');
  const mediaType = (typeof part.mediaType === 'string' ? part.mediaType : declared ?? '').slice(0, 100);
  const kind = sniff(bytes, mediaType);
  const canonicalType = kind === 'pdf' ? 'application/pdf'
    : kind === 'image' ? (starts(bytes, [0x89, 0x50, 0x4e, 0x47]) ? 'image/png' : ascii(bytes, 8, 12) === 'WEBP' ? 'image/webp' : ascii(bytes, 4, 8) === 'ftyp' ? 'image/heic' : 'image/jpeg')
    : kind === 'audio' ? (mediaType.startsWith('audio/') ? mediaType.split(';')[0] : ascii(bytes, 0, 4) === 'OggS' ? 'audio/ogg' : ascii(bytes, 0, 4) === 'RIFF' ? 'audio/wav' : 'audio/mpeg')
    : mediaType;
  return { kind, bytes, mediaType: canonicalType };
}

// The production fetch: https only (also after redirects), no credentials,
// a size cap that is enforced while reading, and a timeout.
export function httpsFetcher(timeoutMs: number): FetchBytes {
  return async (url, maxBytes) => {
    const res = await fetch(url, { redirect: 'follow', credentials: 'omit', signal: AbortSignal.timeout(timeoutMs) });
    if (!res.ok || !/^https:\/\//i.test(res.url || url)) throw new MediaError('fetch_failed');
    const declared = Number(res.headers.get('content-length') ?? '0');
    if (declared > maxBytes) throw new MediaError('too_large');
    const reader = res.body?.getReader();
    if (!reader) throw new MediaError('fetch_failed');
    const chunks: Uint8Array[] = [];
    let size = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > maxBytes) { await reader.cancel().catch(() => {}); throw new MediaError('too_large'); }
      chunks.push(value);
    }
    const out = new Uint8Array(size);
    let at = 0;
    for (const c of chunks) { out.set(c, at); at += c.length; }
    return out;
  };
}
