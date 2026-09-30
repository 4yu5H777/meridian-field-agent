// Mock distributor: the logic, with no network of its own. server.mjs puts it
// behind HTTP. Plain JavaScript, no dependencies.
//
// Orders:    accept(order, idempotencyKey) -> { distributor_ref, created }
//            The same order_ref / key always returns the same distributor_ref.
// Callbacks: callback(ref, status, { eventId, reason }) builds a status event and
//            POSTs it to the agent, signed with HMAC-SHA256 over the raw body.
//            replay(eventId) sends the IDENTICAL event again (duplicate test).
//            Statuses are free text on purpose: ACCEPTED, DISPATCHED, REJECTED,
//            or anything else, to test how the agent handles surprises.
import { createHmac, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const REF_OK = /^MER-ORDER-[0-9]{1,18}$/;

// Canonical JSON: object keys sorted at every level, no whitespace. Callbacks
// are SENT in this form and SIGNED over it, so a receiver that only sees the
// parsed body (Lua webhooks do) can rebuild the exact signed bytes.
export function canonicalJson(v) {
  if (Array.isArray(v)) return '[' + v.map(canonicalJson).join(',') + ']';
  if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canonicalJson(v[k])).join(',') + '}';
  return JSON.stringify(v);
}

export function sign(secret, body) {
  return 'sha256=' + createHmac('sha256', secret).update(body).digest('hex');
}

export function validateOrder(o) {
  if (!o || typeof o !== 'object') return 'body must be a JSON object';
  if (typeof o.order_ref !== 'string' || !REF_OK.test(o.order_ref)) return 'order_ref must look like MER-ORDER-<n>';
  if (!o.chemist || typeof o.chemist.code !== 'string') return 'chemist.code is required';
  if (!Array.isArray(o.lines) || o.lines.length < 1 || o.lines.length > 50) return 'lines must have 1 to 50 items';
  for (const l of o.lines) {
    if (!l || typeof l.sku !== 'string' || !Number.isInteger(l.qty) || l.qty < 1) return 'each line needs a sku and a positive integer qty';
  }
  if (!Number.isInteger(o.total_paise) || o.total_paise < 1) return 'total_paise must be a positive integer';
  return null;
}

export class Distributor {
  // opts: { callbackUrl, callbackSecret, send(url, body, headers) -> Promise<{status}>, now(), dataFile, schedule(fn, ms) }
  constructor(opts = {}) {
    this.opts = opts;
    this.orders = new Map();      // distributor_ref -> order record
    this.byKey = new Map();       // order_ref -> distributor_ref
    this.events = new Map();      // event_id -> { body, headers }
    this.seq = 0;
    if (opts.dataFile && existsSync(opts.dataFile)) {
      const d = JSON.parse(readFileSync(opts.dataFile, 'utf8'));
      this.seq = d.seq ?? 0;
      for (const o of d.orders ?? []) { this.orders.set(o.distributor_ref, o); this.byKey.set(o.order_ref, o.distributor_ref); }
      for (const e of d.events ?? []) this.events.set(e.event_id, e);
    }
  }

  now() { return this.opts.now ? this.opts.now() : new Date(); }

  save() {
    if (!this.opts.dataFile) return;
    writeFileSync(this.opts.dataFile, JSON.stringify({ seq: this.seq, orders: [...this.orders.values()], events: [...this.events.values()] }, null, 2));
  }

  accept(order, idempotencyKey) {
    const err = validateOrder(order);
    if (err) return { error: err };
    if (idempotencyKey !== undefined && idempotencyKey !== order.order_ref) return { error: 'X-Idempotency-Key must equal order_ref' };
    const existing = this.byKey.get(order.order_ref);
    if (existing) return { distributor_ref: existing, created: false };
    this.seq += 1;
    const ref = `MD-${String(this.seq).padStart(6, '0')}`;
    this.orders.set(ref, { distributor_ref: ref, order_ref: order.order_ref, received_at: this.now().toISOString(),
                           chemist: order.chemist, lines: order.lines, total_paise: order.total_paise, statuses: [] });
    this.byKey.set(order.order_ref, ref);
    this.save();
    return { distributor_ref: ref, created: true };
  }

  // Build, remember and send one status event. Unknown refs are allowed on
  // purpose (the agent must ignore callbacks for orders it never sent).
  async callback(ref, status, { eventId, reason } = {}) {
    if (typeof ref !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(ref)) return { error: 'distributor_ref is required' };
    if (typeof status !== 'string' || !/^[A-Za-z_]{1,32}$/.test(status)) return { error: 'status must be a word' };
    const order = this.orders.get(ref);
    const event = {
      event_id: eventId && /^[A-Za-z0-9_-]{1,64}$/.test(eventId) ? eventId : `EVT-${randomUUID()}`,
      distributor_ref: ref,
      order_ref: order?.order_ref ?? null,
      status: status.toUpperCase(),
      occurred_at: this.now().toISOString(),
      ...(reason ? { reason: String(reason).slice(0, 300) } : {}),
    };
    if (this.events.has(event.event_id)) return this.replay(event.event_id);
    const body = canonicalJson(event);
    const stored = { event_id: event.event_id, body, sent: [] };
    this.events.set(event.event_id, stored);
    order?.statuses.push({ status: event.status, event_id: event.event_id, at: event.occurred_at });
    this.save();
    return this.deliver(stored);
  }

  // Send the exact same bytes again, same event_id and signature.
  async replay(eventId) {
    const stored = this.events.get(eventId);
    if (!stored) return { error: 'unknown event_id' };
    return this.deliver(stored);
  }

  async deliver(stored) {
    const { callbackUrl, callbackSecret, send } = this.opts;
    if (!callbackUrl || !callbackSecret) return { event_id: stored.event_id, delivered: false, error: 'callback URL / secret not configured' };
    const headers = { 'content-type': 'application/json', 'x-event-id': stored.event_id, 'x-signature': sign(callbackSecret, stored.body) };
    try {
      const doSend = send ?? (async (url, body, h) => { const r = await fetch(url, { method: 'POST', body, headers: h }); return { status: r.status }; });
      const r = await doSend(callbackUrl, stored.body, headers);
      stored.sent.push({ at: this.now().toISOString(), http_status: r.status });
      this.save();
      return { event_id: stored.event_id, delivered: r.status >= 200 && r.status < 300, http_status: r.status };
    } catch (e) {
      stored.sent.push({ at: this.now().toISOString(), error: e?.name ?? 'Error' });
      this.save();
      return { event_id: stored.event_id, delivered: false, error: e?.name ?? 'Error' };
    }
  }

  // Automatic life cycle after an order is accepted: ACCEPTED, then DISPATCHED.
  scheduleLifecycle(ref, acceptMs, dispatchMs) {
    const schedule = this.opts.schedule ?? ((fn, ms) => setTimeout(fn, ms));
    schedule(() => this.callback(ref, 'ACCEPTED'), acceptMs);
    schedule(() => this.callback(ref, 'DISPATCHED'), dispatchMs);
  }
}
