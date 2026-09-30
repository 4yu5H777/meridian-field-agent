// Unit tests: reviewer registration webhook (key, shape, no leaks).
//   node --test tests/registration.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleRegistration, keyMatches, MIN_KEY_LENGTH } from '../src/lib/registration.ts';

const KEY = 'k'.repeat(MIN_KEY_LENGTH) + '-demo';
function db(reply: unknown = { ok: true, status: 'registered', as: 'Deepak Chauhan' }) {
  const calls: unknown[][] = [];
  const register = async (...a: unknown[]) => { calls.push(a); if (reply instanceof Error) throw reply; return reply; };
  return { calls, register };
}
const call = (headers: unknown, body: unknown, d = db(), key: string | undefined = KEY) =>
  handleRegistration({ headers, body, key, register: d.register as never, timeoutMs: 1000 });

test('the key: constant-length compare; missing, wrong or unset keys do nothing', async () => {
  assert.equal(await keyMatches(KEY, KEY), true);
  for (const bad of [undefined, '', KEY.slice(0, -1), KEY + 'x', 'x'.repeat(300), 42]) assert.equal(await keyMatches(KEY, bad), false);
  const d = db();
  assert.deepEqual(await call({}, { role: 'rep', phone: '+919800000000' }, d), { ok: false, error: 'unauthorized' });
  assert.deepEqual(await call({ 'x-registration-key': 'guess' }, { role: 'rep', phone: '+919800000000' }, d), { ok: false, error: 'unauthorized' });
  assert.deepEqual(await call({ 'x-registration-key': 'short' }, { role: 'rep', phone: '+91' }, d, 'short'), { ok: false, error: 'not configured' });
  assert.deepEqual(await call({ 'x-registration-key': KEY }, { role: 'rep', phone: '+91' }, d, ''), { ok: false, error: 'not configured' });
  assert.equal(d.calls.length, 0);
});

test('a phone and an email for one role; the header name is case-insensitive; the body may be a string', async () => {
  const d = db();
  const r = await call({ 'X-Registration-Key': KEY }, JSON.stringify({ role: 'rep', phone: ' +91 98000 00000 ', email: 'me@example.com' }), d);
  assert.deepEqual(r, { ok: true, results: [
    { channel: 'whatsapp', ok: true, status: 'registered', as: 'Deepak Chauhan' },
    { channel: 'email', ok: true, status: 'registered', as: 'Deepak Chauhan' }] });
  assert.deepEqual(d.calls, [['rep', 'whatsapp', '+91 98000 00000', false], ['rep', 'email', 'me@example.com', false]]);
  const rm = db({ ok: true, status: 'removed' });
  assert.equal((await call({ 'x-registration-key': KEY }, { remove: true, email: 'me@example.com', role: 'admin' }, rm)).ok, true);
  assert.deepEqual(rm.calls, [[null, 'email', 'me@example.com', true]]);          // removal ignores any role
});

test('bad shapes are refused before the database', async () => {
  const d = db();
  for (const body of [null, 'not json', [], { role: 'admin', phone: '+91' }, { role: 'rep' }, { role: 'rep', phone: '' }, { role: 'rep', phone: 'x'.repeat(41) }, { role: ['rep'], phone: '+91' }]) {
    assert.equal((await call({ 'x-registration-key': KEY }, body, d)).ok, false, JSON.stringify(body));
  }
  assert.equal(d.calls.length, 0);
});

test('database refusals are passed on by name; failures never leak', async () => {
  assert.deepEqual(await call({ 'x-registration-key': KEY }, { role: 'manager', email: 'ravi.kumar@meridian.example' }, db({ ok: false, error: 'taken' })),
    { ok: false, results: [{ channel: 'email', ok: false, error: 'taken' }] });
  for (const reply of [new Error('connect postgresql://u:secret@h/db'), { ok: false, error: 'GUARD: something internal' }, null]) {
    const r = await call({ 'x-registration-key': KEY }, { role: 'rep', phone: '+919800000000' }, db(reply));
    assert.deepEqual(r, { ok: false, results: [{ channel: 'whatsapp', ok: false, error: 'failed' }] });
    assert.doesNotMatch(JSON.stringify(r), /secret|postgres|GUARD/);
  }
});
