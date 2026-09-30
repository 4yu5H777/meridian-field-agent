// Unit tests: the distributor submission loop, with stand-ins.
//   node --test tests/submit.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { submitOrders, DistributorError, type ClaimedSubmission, type SubmitDeps } from '../src/lib/submit.ts';

const row = (id: number, over: Partial<ClaimedSubmission> = {}): ClaimedSubmission =>
  ({ order_id: String(id), idempotency_key: `MER-ORDER-${id}`, attempts: 1, payload: { order_ref: `MER-ORDER-${id}` }, ...over });

function deps(over: Partial<SubmitDeps> = {}) {
  const sent: [unknown, string][] = []; const recorded: [number, string, string][] = []; const failed: [number, string][] = [];
  const d: SubmitDeps = {
    claim: async () => [row(1)],
    send: async (payload, key) => { sent.push([payload, key]); return { distributor_ref: 'MD-000001' }; },
    record: async (id, key, ref) => { recorded.push([id, key, ref]); return 'submitted'; },
    fail: async (id, e) => { failed.push([id, e]); return 'pending'; },
    limit: 10, sendTimeoutMs: 50, ...over,
  };
  return { d, sent, recorded, failed };
}

test('claim -> send with the idempotency key -> record the reference', async () => {
  const t = deps();
  const r = await submitOrders(t.d);
  assert.deepEqual({ ...r, results: r.results }, { claimed: 1, submitted: 1, retrying: 0, refused: 0, results: ['1: submitted MD-000001'] });
  assert.deepEqual(t.sent, [[{ order_ref: 'MER-ORDER-1' }, 'MER-ORDER-1']]);
  assert.deepEqual(t.recorded, [[1, 'MER-ORDER-1', 'MD-000001']]);
  assert.equal(t.failed.length, 0);
});

test('an already-recorded resend counts as done', async () => {
  const t = deps({ record: async () => 'already_submitted' });
  assert.equal((await submitOrders(t.d)).submitted, 1);
});

test('send failures are retried later: error, timeout, bad or missing reference', async () => {
  for (const send of [
    async () => { throw new Error('postgresql://u:secret@h/db ECONNREFUSED'); },
    async () => { throw new DistributorError('HTTP 503'); },
    () => new Promise<never>(() => {}),
    async () => ({ distributor_ref: '' }),
    async () => ({ distributor_ref: 'x; DROP' }),
  ] as SubmitDeps['send'][]) {
    const t = deps({ send });
    const r = await submitOrders(t.d);
    assert.equal(r.retrying, 1);
    assert.equal(t.recorded.length, 0, 'nothing is recorded without a valid reference');
    assert.equal(t.failed.length, 1);
    assert.doesNotMatch(t.failed[0][1], /secret|postgres/);
  }
});

test('the database refusing to record is final, not retried', async () => {
  for (const result of ['conflict', 'blocked', 'not_confirmed', 'key_mismatch', 'not_queued']) {
    const t = deps({ record: async () => result });
    const r = await submitOrders(t.d);
    assert.deepEqual([r.submitted, r.refused, r.retrying], [0, 1, 0], result);
    assert.equal(t.failed.length, 0);
  }
});

test('a lost database write after the distributor accepted is retried with the same key', async () => {
  const t = deps({ record: async () => { throw new Error('connection reset'); } });
  const r = await submitOrders(t.d);
  assert.equal(r.retrying, 1);
  assert.deepEqual(t.failed, [[1, 'record: Error']]);
});

test('malformed claims are skipped; a failing claim is reported, never thrown', async () => {
  const t = deps({ claim: async () => [row(0), row(2, { idempotency_key: 'EVIL' }), row(3)] });
  const r = await submitOrders(t.d);
  assert.deepEqual([r.claimed, r.submitted, r.refused], [3, 1, 2]);
  assert.deepEqual(t.sent.map((s) => s[1]), ['MER-ORDER-3']);
  const bad = await submitOrders(deps({ claim: async () => { throw new Error('db down'); } }).d);
  assert.deepEqual(bad, { claimed: 0, submitted: 0, retrying: 0, refused: 0, results: [], error: 'claim failed (Error)' });
});
