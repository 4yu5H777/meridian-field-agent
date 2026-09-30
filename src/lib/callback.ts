// A distributor status callback (the distributor-callback webhook). Pure apart
// from Web Crypto, so it can be unit-tested with plain Node.
//
// 1. Authenticity: X-Signature = "sha256=" + hex HMAC-SHA256 over the CANONICAL
//    JSON of the body (keys sorted at every level, no whitespace), keyed with
//    DISTRIBUTOR_CALLBACK_SECRET from the environment. Lua webhooks receive the
//    parsed body, not the raw bytes, so the signed form must be rebuildable;
//    the distributor sends exactly that form. Compared in constant time.
// 2. Shape: event id, distributor ref, status word, optional timestamp/reason.
// 3. Everything else (duplicate, out of order, unknown order, unknown status,
//    allowed transitions, ledger, rep notification) is decided by
//    meridian.record_distributor_event and its triggers.
export function canonicalJson(v: unknown): string {
  if (Array.isArray(v)) return '[' + v.map(canonicalJson).join(',') + ']';
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return '{' + Object.keys(o).sort().map((k) => JSON.stringify(k) + ':' + canonicalJson(o[k])).join(',') + '}';
  }
  return JSON.stringify(v) ?? 'null';
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(message)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function signCallback(secret: string, body: unknown): Promise<string> {
  return 'sha256=' + await hmacHex(secret, canonicalJson(body));
}

export async function verifyCallback(secret: string, body: unknown, header: unknown): Promise<boolean> {
  if (typeof header !== 'string' || !/^sha256=[0-9a-f]{64}$/.test(header)) return false;
  return constantTimeEqual(await signCallback(secret, body), header);
}

// Header lookup that does not depend on the platform's casing.
export function header(headers: unknown, name: string): unknown {
  if (!headers || typeof headers !== 'object') return undefined;
  const want = name.toLowerCase();
  for (const [k, v] of Object.entries(headers as Record<string, unknown>)) {
    if (k.toLowerCase() === want) return Array.isArray(v) ? v[0] : v;
  }
  return undefined;
}

export type CallbackEvent = { event_id: string; distributor_ref: string; status: string; occurred_at: string | null; payload: Record<string, unknown> };

export function parseCallback(body: unknown): CallbackEvent | null {
  const b = body as Record<string, unknown>;
  if (!b || typeof b !== 'object' || Array.isArray(b)) return null;
  if (typeof b.event_id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(b.event_id)) return null;
  if (typeof b.distributor_ref !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(b.distributor_ref)) return null;
  if (typeof b.status !== 'string' || !/^[A-Za-z_]{1,32}$/.test(b.status)) return null;
  let occurred: string | null = null;
  if (typeof b.occurred_at === 'string' && b.occurred_at.length <= 40 && !Number.isNaN(Date.parse(b.occurred_at))) {
    occurred = new Date(b.occurred_at).toISOString();
  }
  // Store only the fields we know, bounded; the raw event is not trusted further.
  const payload: Record<string, unknown> = {
    event_id: b.event_id, distributor_ref: b.distributor_ref, status: b.status, occurred_at: b.occurred_at ?? null,
    order_ref: typeof b.order_ref === 'string' ? b.order_ref.slice(0, 64) : null,
    ...(typeof b.reason === 'string' ? { reason: b.reason.slice(0, 300) } : {}),
  };
  return { event_id: b.event_id, distributor_ref: b.distributor_ref, status: b.status, occurred_at: occurred, payload };
}

export type CallbackResponse = { ok: boolean; result?: string; error?: string };

export async function handleCallback(input: {
  headers: unknown;
  body: unknown;
  secret: string | undefined;
  record: (e: CallbackEvent) => Promise<string>;
  timeoutMs: number;
}): Promise<CallbackResponse> {
  if (!input.secret || input.secret.length < 16) return { ok: false, error: 'not configured' };
  let body = input.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { return { ok: false, error: 'invalid body' }; }
  }
  if (!(await verifyCallback(input.secret, body, header(input.headers, 'x-signature')))) {
    return { ok: false, error: 'invalid signature' };
  }
  const event = parseCallback(body);
  if (!event) return { ok: false, error: 'invalid event' };
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), input.timeoutMs); });
  try {
    const result = await Promise.race([input.record(event), timeout]);
    return { ok: true, result: /^[a-z_]{1,30}$/.test(result) ? result : 'unexpected' };
  } catch {
    return { ok: false, error: 'could not record' };
  } finally {
    clearTimeout(timer);
  }
}
