// Unit tests: callback signature, parsing and handling; the rep's status message.
//   node --test tests/callback.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { canonicalJson, signCallback, verifyCallback, parseCallback, handleCallback, header, type CallbackEvent } from '../src/lib/callback.ts';
import { renderNotification } from '../src/lib/notify.ts';
import { canonicalJson as mockCanonical, sign as mockSign } from '../mock-distributor/distributor.mjs';

const SECRET = 'callback-secret-0123456789';
const event = (over: Record<string, unknown> = {}) => ({ event_id: 'EVT-1', distributor_ref: 'MD-000001', order_ref: 'MER-ORDER-81',
  status: 'ACCEPTED', occurred_at: '2026-09-29T10:00:00.000Z', ...over });

test('canonical JSON and signature agree byte for byte with the mock distributor', async () => {
  const e = event({ reason: 'x', nested: { b: 1, a: [2, { d: null, c: 'é' }] } });
  assert.equal(canonicalJson(e), mockCanonical(e));
  assert.equal(await signCallback(SECRET, e), mockSign(SECRET, mockCanonical(e)));
  // Key order in the parsed body does not matter.
  const shuffled = Object.fromEntries(Object.entries(e).reverse());
  assert.equal(await verifyCallback(SECRET, shuffled, mockSign(SECRET, mockCanonical(e))), true);
});

test('verification refuses tampering, the wrong key and malformed headers', async () => {
  const good = await signCallback(SECRET, event());
  assert.equal(await verifyCallback(SECRET, event(), good), true);
  assert.equal(await verifyCallback(SECRET, event({ status: 'DISPATCHED' }), good), false);
  assert.equal(await verifyCallback('another-secret-0123456789', event(), good), false);
  for (const h of [undefined, '', 'sha256=', good.toUpperCase(), good.slice(0, -1), 'md5=' + good.slice(7), 42]) {
    assert.equal(await verifyCallback(SECRET, event(), h), false, String(h));
  }
});

test('header lookup ignores case', () => {
  assert.equal(header({ 'X-Signature': 'a' }, 'x-signature'), 'a');
  assert.equal(header({ 'x-signature': ['b', 'c'] }, 'X-SIGNATURE'), 'b');
  assert.equal(header(null, 'x'), undefined);
});

test('parseCallback: only well-formed events, only known fields kept', () => {
  const p = parseCallback(event({ reason: 'r'.repeat(500), extra: 'ignored', occurred_at: '2026-09-29T15:30:00+05:30' }));
  assert.equal(p?.occurred_at, '2026-09-29T10:00:00.000Z');
  assert.equal((p?.payload.reason as string).length, 300);
  assert.equal('extra' in (p?.payload ?? {}), false);
  assert.equal(parseCallback(event({ occurred_at: 'yesterday' }))?.occurred_at, null);
  for (const bad of [null, [], 'x', event({ event_id: '' }), event({ event_id: 'a b' }), event({ distributor_ref: "x'; DROP" }),
                     event({ status: 'ON HOLD!' }), event({ status: 7 })]) {
    assert.equal(parseCallback(bad), null, JSON.stringify(bad));
  }
});

async function run(over: Partial<Parameters<typeof handleCallback>[0]> & { body?: unknown } = {}, sigFor: unknown = event()) {
  const recorded: CallbackEvent[] = [];
  const res = await handleCallback({ headers: { 'x-signature': await signCallback(SECRET, sigFor) }, body: event(), secret: SECRET,
    record: async (e) => { recorded.push(e); return 'applied'; }, timeoutMs: 50, ...over });
  return { res, recorded };
}

test('handleCallback: a signed, well-formed event is recorded', async () => {
  const { res, recorded } = await run();
  assert.deepEqual(res, { ok: true, result: 'applied' });
  assert.deepEqual(recorded.map((e) => [e.event_id, e.distributor_ref, e.status]), [['EVT-1', 'MD-000001', 'ACCEPTED']]);
  // A body the platform hands over as a string is parsed first.
  const s = await run({ body: JSON.stringify(event()) });
  assert.equal(s.res.ok, true);
});

test('handleCallback: nothing is recorded without a valid signature or a secret', async () => {
  for (const over of [{ headers: {} }, { headers: { 'x-signature': 'sha256=' + '0'.repeat(64) } }, { secret: undefined }, { secret: 'short' },
                      { body: '{not json' }]) {
    const { res, recorded } = await run(over);
    assert.equal(res.ok, false, JSON.stringify(over));
    assert.equal(recorded.length, 0);
  }
  const forged = await run({ body: event({ status: 'REJECTED' }) });          // signature is for ACCEPTED
  assert.deepEqual(forged.res, { ok: false, error: 'invalid signature' });
  const badShape = await run({ body: event({ event_id: 'bad id' }) }, event({ event_id: 'bad id' }));
  assert.deepEqual(badShape.res, { ok: false, error: 'invalid event' });
});

test('handleCallback: database outcomes pass through; failures are generic', async () => {
  for (const r of ['duplicate', 'no_change', 'ignored_out_of_order', 'unknown_order', 'unknown_status']) {
    assert.deepEqual((await run({ record: async () => r })).res, { ok: true, result: r });
  }
  assert.deepEqual((await run({ record: async () => { throw new Error('postgresql://u:secret@h'); } })).res, { ok: false, error: 'could not record' });
  assert.deepEqual((await run({ record: () => new Promise<never>(() => {}) })).res, { ok: false, error: 'could not record' });
});

test('rep status messages', () => {
  const row = (status: string, reason = '') => ({ id: '9', kind: 'order_status_to_rep', channel: 'whatsapp', address: '+919000000042',
    payload: { event_id: 5, order_id: 81, status, distributor_ref: 'MD-000001', chemist_name: 'Singh Medical Agency', order_total_paise: 19000, reason } });
  assert.equal(renderNotification(row('accepted')).text, 'Order #81 for Singh Medical Agency (₹190.00, distributor ref MD-000001) was accepted by the distributor.');
  assert.equal(renderNotification(row('dispatched')).text, 'Order #81 for Singh Medical Agency (₹190.00, distributor ref MD-000001) has been dispatched.');
  assert.equal(renderNotification(row('distributor_rejected', 'out of stock')).text,
    'Order #81 for Singh Medical Agency (₹190.00, distributor ref MD-000001) was REJECTED by the distributor. Reason given: "out of stock". The chemist has not been charged for it.');
  assert.throws(() => renderNotification(row('on_hold')));
});
