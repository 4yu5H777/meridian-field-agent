// Mock distributor tests: real HTTP server on a random port, callbacks captured
// by a local stand-in for the agent's webhook.
//   node --test mock-distributor/distributor.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createDistributorServer } from './server.mjs';
import { sign } from './distributor.mjs';

const KEY = 'test-key-0123456789abcdef';
const SECRET = 'callback-secret-for-tests';
const order = (n = 1) => ({ order_ref: `MER-ORDER-${n}`, order_id: n, chemist: { code: 'CH-10', name: 'Singh Medical Agency' },
  lines: [{ sku: 'CET-10-10', qty: 10, free_qty: 0 }], total_paise: 19000 });

async function listen(server) {
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return `http://127.0.0.1:${server.address().port}`;
}

async function setup(extraEnv = {}) {
  const received = [];
  const agent = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => { received.push({ body, headers: req.headers }); res.writeHead(200); res.end('{}'); });
  });
  const agentUrl = await listen(agent);
  const { server, distributor } = createDistributorServer({ DISTRIBUTOR_API_KEY: KEY, CALLBACK_URL: `${agentUrl}/hook`, CALLBACK_SECRET: SECRET,
                                                           AUTO_CALLBACKS: 'off', ...extraEnv });
  const url = await listen(server);
  const call = (path, { method = 'POST', body, key = KEY, idem } = {}) => fetch(url + path, {
    method, headers: { 'content-type': 'application/json', ...(key ? { authorization: `Bearer ${key}` } : {}), ...(idem ? { 'x-idempotency-key': idem } : {}) },
    ...(body !== undefined ? { body: typeof body === 'string' ? body : JSON.stringify(body) } : {}) });
  const close = () => { server.close(); agent.close(); };
  return { call, received, distributor, close };
}

test('accepts an order once; a resend with the same key gets the same reference', async () => {
  const t = await setup();
  try {
    const r1 = await t.call('/orders', { body: order(1), idem: 'MER-ORDER-1' });
    assert.equal(r1.status, 201);
    const { distributor_ref } = await r1.json();
    assert.match(distributor_ref, /^MD-[0-9]{6}$/);
    const r2 = await t.call('/orders', { body: order(1), idem: 'MER-ORDER-1' });
    assert.equal(r2.status, 200);
    assert.equal((await r2.json()).distributor_ref, distributor_ref);
    const r3 = await t.call('/orders', { body: order(2), idem: 'MER-ORDER-2' });
    assert.notEqual((await r3.json()).distributor_ref, distributor_ref);
  } finally { t.close(); }
});

test('refuses unauthenticated, mismatched or malformed orders', async () => {
  const t = await setup();
  try {
    assert.equal((await t.call('/orders', { body: order(1), key: null })).status, 401);
    assert.equal((await t.call('/orders', { body: order(1), key: 'wrong-key-0123456789ab' })).status, 401);
    assert.equal((await t.call('/orders', { body: order(1), idem: 'MER-ORDER-2' })).status, 400);
    for (const bad of [{ ...order(1), order_ref: 'x' }, { ...order(1), lines: [] }, { ...order(1), lines: [{ sku: 'X', qty: 1.5 }] },
                       { ...order(1), total_paise: 0 }, { ...order(1), chemist: null }]) {
      assert.equal((await t.call('/orders', { body: bad })).status, 400, JSON.stringify(bad));
    }
    assert.equal((await t.call('/orders', { body: '{not json' })).status, 400);
    assert.equal(t.distributor.orders.size, 0);
  } finally { t.close(); }
});

test('callbacks are signed; a replay is byte-identical (duplicate test)', async () => {
  const t = await setup();
  try {
    const { distributor_ref } = await (await t.call('/orders', { body: order(7), idem: 'MER-ORDER-7' })).json();
    const r = await (await t.call('/admin/callback', { body: { distributor_ref, status: 'accepted', event_id: 'EVT-demo-1' } })).json();
    assert.deepEqual(r, { event_id: 'EVT-demo-1', delivered: true, http_status: 200 });
    await t.call('/admin/replay', { body: { event_id: 'EVT-demo-1' } });
    await t.call('/admin/callback', { body: { distributor_ref, status: 'ACCEPTED', event_id: 'EVT-demo-1' } });   // same id again -> replay
    assert.equal(t.received.length, 3);
    const [a, b, c] = t.received;
    assert.equal(a.body, b.body); assert.equal(b.body, c.body);
    const ev = JSON.parse(a.body);
    assert.deepEqual({ ...ev, occurred_at: 'x' }, { event_id: 'EVT-demo-1', distributor_ref, order_ref: 'MER-ORDER-7', status: 'ACCEPTED', occurred_at: 'x' });
    assert.equal(a.headers['x-signature'], sign(SECRET, a.body));
    assert.equal(a.headers['x-event-id'], 'EVT-demo-1');
  } finally { t.close(); }
});

test('out-of-order, unknown order and unknown status can all be produced on demand', async () => {
  const t = await setup();
  try {
    const { distributor_ref } = await (await t.call('/orders', { body: order(8), idem: 'MER-ORDER-8' })).json();
    await t.call('/admin/callback', { body: { distributor_ref, status: 'DISPATCHED' } });
    await t.call('/admin/callback', { body: { distributor_ref, status: 'ACCEPTED' } });
    await t.call('/admin/callback', { body: { distributor_ref: 'MD-999999', status: 'DISPATCHED' } });
    await t.call('/admin/callback', { body: { distributor_ref, status: 'ON_HOLD', reason: 'stock check' } });
    await t.call('/admin/callback', { body: { distributor_ref, status: 'REJECTED', reason: 'out of stock' } });
    const evs = t.received.map((r) => JSON.parse(r.body));
    assert.deepEqual(evs.map((e) => e.status), ['DISPATCHED', 'ACCEPTED', 'DISPATCHED', 'ON_HOLD', 'REJECTED']);
    assert.equal(evs[2].order_ref, null);
    assert.equal(evs[4].reason, 'out of stock');
    assert.equal(new Set(evs.map((e) => e.event_id)).size, 5);
    assert.equal((await t.call('/admin/callback', { body: { distributor_ref, status: 'drop table' } })).status, 400);
    assert.equal((await t.call('/admin/replay', { body: { event_id: 'EVT-nope' } })).status, 404);
  } finally { t.close(); }
});

test('automatic life cycle: ACCEPTED then DISPATCHED after a new order', async () => {
  const t = await setup({ AUTO_CALLBACKS: 'on', ACCEPT_AFTER_MS: '20', DISPATCH_AFTER_MS: '60' });
  try {
    await t.call('/orders', { body: order(9), idem: 'MER-ORDER-9' });
    await t.call('/orders', { body: order(9), idem: 'MER-ORDER-9' });   // a resend does not start a second life cycle
    await new Promise((r) => setTimeout(r, 250));
    assert.deepEqual(t.received.map((r) => JSON.parse(r.body).status), ['ACCEPTED', 'DISPATCHED']);
  } finally { t.close(); }
});

test('refuses to start without a real API key', () => {
  assert.throws(() => createDistributorServer({ DISTRIBUTOR_API_KEY: 'short' }), /DISTRIBUTOR_API_KEY/);
});
