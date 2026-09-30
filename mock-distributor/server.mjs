// Mock distributor HTTP service.
//   DISTRIBUTOR_API_KEY=... CALLBACK_URL=https://<agent webhook> CALLBACK_SECRET=... node mock-distributor/server.mjs
//
// Environment (never logged):
//   PORT                 default 8787
//   DISTRIBUTOR_API_KEY  required; the agent sends it as "Authorization: Bearer <key>"; also guards /admin
//   CALLBACK_URL         the agent's distributor webhook (Phase 3); callbacks are skipped until set
//   CALLBACK_SECRET      HMAC-SHA256 key for the X-Signature header of each callback
//   AUTO_CALLBACKS       "on" (default) sends ACCEPTED, then DISPATCHED, after each new order
//   ACCEPT_AFTER_MS      default 60000;  DISPATCH_AFTER_MS default 300000
//   DATA_FILE            optional JSON file so orders/events survive a restart
//
// Endpoints:
//   POST /orders                         accept an order (idempotent on order_ref = X-Idempotency-Key)
//   GET  /orders                         list orders and their callbacks          (admin)
//   POST /admin/callback                 {distributor_ref, status, event_id?, reason?} send one now (admin)
//   POST /admin/replay                   {event_id} send the SAME event again           (admin)
//   GET  /health
import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { Distributor } from './distributor.mjs';

function authorized(req, key) {
  const got = Buffer.from(String(req.headers.authorization ?? ''));
  const want = Buffer.from(`Bearer ${key}`);
  return got.length === want.length && timingSafeEqual(got, want);
}

async function readJson(req, limit = 256 * 1024) {
  let size = 0; const chunks = [];
  for await (const c of req) { size += c.length; if (size > limit) throw new Error('too large'); chunks.push(c); }
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

export function createDistributorServer(env = process.env, distributor = undefined) {
  const key = env.DISTRIBUTOR_API_KEY;
  if (!key || key.length < 16) throw new Error('DISTRIBUTOR_API_KEY must be set (16+ characters)');
  const d = distributor ?? new Distributor({ callbackUrl: env.CALLBACK_URL, callbackSecret: env.CALLBACK_SECRET, dataFile: env.DATA_FILE });
  const auto = (env.AUTO_CALLBACKS ?? 'on') !== 'off';
  const acceptMs = Number(env.ACCEPT_AFTER_MS ?? 60000);
  const dispatchMs = Number(env.DISPATCH_AFTER_MS ?? 300000);
  const send = (res, status, body) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };

  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://x');
      if (req.method === 'GET' && url.pathname === '/health') return send(res, 200, { ok: true });
      if (!authorized(req, key)) return send(res, 401, { error: 'unauthorized' });

      if (req.method === 'POST' && url.pathname === '/orders') {
        const r = d.accept(await readJson(req), req.headers['x-idempotency-key']);
        if (r.error) return send(res, 400, { error: r.error });
        if (r.created && auto) d.scheduleLifecycle(r.distributor_ref, acceptMs, dispatchMs);
        return send(res, r.created ? 201 : 200, { distributor_ref: r.distributor_ref, status: 'received' });
      }
      if (req.method === 'GET' && url.pathname === '/orders') {
        return send(res, 200, { orders: [...d.orders.values()], events: [...d.events.values()].map((e) => ({ ...JSON.parse(e.body), sent: e.sent })) });
      }
      if (req.method === 'POST' && url.pathname === '/admin/callback') {
        const b = await readJson(req);
        const r = await d.callback(b.distributor_ref, b.status, { eventId: b.event_id, reason: b.reason });
        return send(res, r.error && !r.event_id ? 400 : 200, r);
      }
      if (req.method === 'POST' && url.pathname === '/admin/replay') {
        const r = await d.replay((await readJson(req)).event_id);
        return send(res, r.error && !r.event_id ? 404 : 200, r);
      }
      return send(res, 404, { error: 'not found' });
    } catch {
      return send(res, 400, { error: 'bad request' });
    }
  });
  return { server, distributor: d };
}

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, '/')}` || process.argv[1]?.endsWith('server.mjs')) {
  const { server } = createDistributorServer();
  const port = Number(process.env.PORT ?? 8787);
  server.listen(port, () => console.log(`mock distributor listening on :${port}`));
}
