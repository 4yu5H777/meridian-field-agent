// Unit tests: the identity gate lets through only a verified, registered
// sender and blocks every other path, including failures.
//   node --test tests/identity-gate.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { screenTurn, REPLY_UNREGISTERED, REPLY_WRONG_CHANNEL, REPLY_UNAVAILABLE, type ScreenResult } from '../src/lib/identityGate.ts';

const WA = { channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'no' as const, profile: { mobileNumbers: ['+919000000002'] } };

function db(result: ScreenResult | Error | 'hang') {
  const calls: unknown[][] = [];
  const screen = async (...a: unknown[]) => {
    calls.push(a);
    if (result === 'hang') return await new Promise<ScreenResult>(() => {});
    if (result instanceof Error) throw result;
    return result;
  };
  return { calls, screen };
}

test('each registered role proceeds; only channel and contacts go to the database', async () => {
  for (const role of ['rep', 'area_manager', 'regional_head']) {
    const d = db({ result: 'ok', role });
    const r = await screenTurn({ ...WA, screen: d.screen, timeoutMs: 1000 });
    assert.deepEqual(r, { action: 'proceed', log: `ok (${role})` });
    assert.deepEqual(d.calls, [['whatsapp', ['+919000000002']]]);
  }
  const email = db({ result: 'ok', role: 'area_manager' });
  const r = await screenTurn({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: { emailAddresses: ['Vikram@Meridian.example'] }, screen: email.screen, timeoutMs: 1000 });
  assert.equal(r.action, 'proceed');
  assert.equal(email.calls.length, 1);
});

test('unknown and ambiguous senders get the same bare refusal', async () => {
  for (const result of ['unknown_sender', 'ambiguous_sender']) {
    const r = await screenTurn({ ...WA, screen: db({ result }).screen, timeoutMs: 1000 });
    assert.deepEqual(r, { action: 'block', response: REPLY_UNREGISTERED, log: `blocked (${result})` });
  }
  assert.doesNotMatch(REPLY_UNREGISTERED, /\d{4}|@|₹|order|chemist/i);
});

test('wrong channel, code-invoked, mismatched or contact-less turns never reach the database', async () => {
  const cases: [Parameters<typeof screenTurn>[0] extends infer T ? Partial<T> : never, string][] = [
    [{ channel: 'dev', requestChannel: 'dev' }, REPLY_WRONG_CHANNEL],
    [{ channel: 'web', requestChannel: 'web' }, REPLY_WRONG_CHANNEL],
    [{ channel: undefined, requestChannel: undefined }, REPLY_WRONG_CHANNEL],
    [{ invoked: 'yes' }, REPLY_UNAVAILABLE],
    [{ invoked: 'unknown' }, REPLY_UNAVAILABLE],
    [{ requestChannel: 'email' }, REPLY_UNAVAILABLE],
    [{ profile: {} }, REPLY_UNREGISTERED],
    [{ profile: null }, REPLY_UNREGISTERED],
    [{ profile: { emailAddresses: ['a@b.example'] } }, REPLY_UNREGISTERED],   // email only, on WhatsApp
  ];
  for (const [patch, reply] of cases) {
    const d = db({ result: 'ok', role: 'rep' });
    const r = await screenTurn({ ...WA, ...patch, screen: d.screen, timeoutMs: 1000 } as Parameters<typeof screenTurn>[0]);
    assert.equal(r.action, 'block', JSON.stringify(patch));
    assert.equal((r as { response: string }).response, reply, JSON.stringify(patch));
    assert.equal(d.calls.length, 0, JSON.stringify(patch));
  }
});

test('every failure blocks: throw, timeout, no row, odd result, ok without a known role', async () => {
  const bad: (ScreenResult | Error | 'hang')[] = [
    new Error('connect failed postgresql://u:secret@h/db'), 'hang', null, undefined, {}, { result: 'bad_channel' },
    { result: 'ok' }, { result: 'ok', role: 'admin' }, { result: 'ok', role: ['rep'] }, { result: ['ok'], role: 'rep' },
  ];
  for (const res of bad) {
    const r = await screenTurn({ ...WA, screen: db(res).screen, timeoutMs: 20 });
    assert.equal(r.action, 'block', String(res));
    assert.equal((r as { response: string }).response, REPLY_UNAVAILABLE);
    assert.doesNotMatch(r.log, /secret|postgres/);
  }
});
