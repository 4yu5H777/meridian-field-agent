// Unit tests for order intake (src/lib/intake.ts) with a stand-in database.
//   node --test tests/intake.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyMatches, validQuantity, runIntake, MSG_REFUSED, MSG_ERROR, type Candidate, type IntakeDb } from '../src/lib/intake.ts';
import { renderSummary } from '../src/lib/summary.ts';
import { senderContext } from '../src/lib/identity.ts';
import { sampleSummary } from './fixtures.ts';

const c = (id: number, name: string, score: number, isRepAlias = false, detail = 'd'): Candidate => ({ id, name, detail, score, isRepAlias });

test('classify: calibrated cases from the seed data', () => {
  // exact name / alias
  assert.deepEqual(classifyMatches([c(10, 'Singh Medical Agency', 1)]), { kind: 'resolved', id: 10, name: 'Singh Medical Agency', detail: 'd' });
  assert.equal(classifyMatches([c(1, 'Cetimer 10 Tablet', 1), c(2, 'Cetimer Syrup', 0.571)]).kind, 'resolved');
  // two exact hits: Meridol 650 (10s) and (15s)
  const m650 = classifyMatches([c(3, 'Meridol 650', 1, false, 'strip of 10'), c(4, 'Meridol 650', 1, false, 'strip of 15'), c(5, 'Meridol-P 650', 0.571)]);
  assert.equal(m650.kind, 'ambiguous');
  assert.deepEqual(m650.kind === 'ambiguous' && m650.candidates.map((x) => x.id), [3, 4]);
  // the rep's own exact alias beats a global exact alias
  assert.deepEqual(classifyMatches([c(3, 'Meridol 650', 1, true), c(4, 'Meridol 650', 1, false)]).kind, 'resolved');
  // confident fuzzy match with a clear lead
  assert.equal(classifyMatches([c(10, 'Singh Medical Agency', 0.813)]).kind, 'resolved');
  // "ORS": two close candidates -> ask
  const ors = classifyMatches([c(20, 'Meridian ORS Orange', 0.444), c(21, 'Meridian ORS Lemon', 0.4)]);
  assert.equal(ors.kind, 'ambiguous');
  assert.equal(ors.kind === 'ambiguous' && ors.candidates.length, 2);
  // weak single candidates -> ask, not resolve ("singh" 0.429, "xyz pharmacy" 0.45, "multimer" 0.409)
  assert.equal(classifyMatches([c(10, 'Singh Medical Agency', 0.429)]).kind, 'ambiguous');
  assert.equal(classifyMatches([c(11, 'Arogya Pharmacy', 0.45)]).kind, 'ambiguous');
  // another rep's chemist scoring 0.36 against one of yours -> not found
  assert.deepEqual(classifyMatches([c(10, 'Singh Medical Agency', 0.36)]), { kind: 'not_found' });
  assert.deepEqual(classifyMatches([]), { kind: 'not_found' });
  // confident but no clear lead -> ask
  assert.equal(classifyMatches([c(1, 'A', 0.85), c(2, 'B', 0.7)]).kind, 'ambiguous');
  // shortlist: at most 5, nothing under 0.3
  const many = classifyMatches([0.6, 0.55, 0.5, 0.45, 0.42, 0.41, 0.2].map((s, i) => c(i + 1, `P${i}`, s)));
  assert.equal(many.kind === 'ambiguous' && many.candidates.length, 5);
});

test('validQuantity: whole packs 1..100000 only', () => {
  for (const q of [1, 10, 100000]) assert.equal(validQuantity(q), true, String(q));
  for (const q of [0, -1, 2.5, 100001, NaN, Infinity, '10', null, undefined]) assert.equal(validQuantity(q), false, String(q));
});

// ---------------------------------------------------------------------------
const SENDER = senderContext({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: { emailAddresses: ['deepak.chauhan@meridian.example'] } });

function fakeDb(over: Partial<IntakeDb> = {}) {
  const calls: string[] = [];
  const prepared: unknown[] = [];
  const db: IntakeDb = {
    identify: async () => { calls.push('identify'); return { result: 'ok', user_id: 42, role: 'rep' }; },
    matchChemist: async (_r, text) => {
      calls.push(`chemist:${text}`);
      if (/singh medical agency/i.test(text)) return [c(10, 'Singh Medical Agency', 1, false, 'Sector 18')];
      if (/sharma medical store/i.test(text)) return [c(10, 'Singh Medical Agency', 0.36, false, 'Sector 18')];
      return [];
    },
    matchProduct: async (_r, text) => {
      calls.push(`product:${text}`);
      if (/^cetimer$/i.test(text)) return [c(1, 'Cetimer 10 Tablet', 1, false, 'strip of 10'), c(2, 'Cetimer Syrup', 0.571, false, '60 ml bottle')];
      if (/^ors$/i.test(text)) return [c(20, 'Meridian ORS Orange', 0.444, false, '21 g sachet'), c(21, 'Meridian ORS Lemon', 0.4, false, '21 g sachet')];
      if (/^ors orange$/i.test(text)) return [c(20, 'Meridian ORS Orange', 1, false, '21 g sachet')];
      return [];
    },
    repChemist: async (_r, id) => (id === 10 ? { id: 10, name: 'Singh Medical Agency', detail: 'Sector 18' } : null),
    activeProduct: async (id) => (id === 21 ? { id: 21, name: 'Meridian ORS Lemon', detail: '21 g sachet' } : null),
    prepareOrder: async (...args) => { calls.push('prepare'); prepared.push(args); return { order_id: 81, superseded_order_ids: [], summary: sampleSummary() }; },
    ...over,
  };
  return { db, calls, prepared };
}

test('intake: normal order -> one atomic prepare, canonical summary back', async () => {
  const { db, prepared } = fakeDb();
  const out = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 10 }, { product_text: 'ORS orange', quantity: 6 }] },
    SENDER, db, 'test');
  assert.equal(out.status, 'ready');
  assert.equal(out.status === 'ready' && out.summary_text, renderSummary(sampleSummary()));
  assert.equal(out.status === 'ready' && out.confirmation_code, '3867');
  // Only ids and quantities go to the database: no prices, no rep id.
  assert.deepEqual(prepared, [['email', ['deepak.chauhan@meridian.example'], 10,
    [{ product_id: 1, qty: 10, raw_text: 'Cetimer' }, { product_id: 20, qty: 6, raw_text: 'ORS orange' }], 'test', 'text', 'Singh Medical Agency']]);
});

test('intake: the input type is a label from a fixed list; anything else is recorded as text', async () => {
  for (const [source, want] of [['voice', 'voice'], ['excel', 'excel'], ['pdf', 'pdf'], ['photo', 'photo'], [undefined, 'text'], ['admin', 'text'], ['VOICE', 'text']] as const) {
    const { db, prepared } = fakeDb();
    await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 10 }], source }, SENDER, db, 'test');
    assert.equal((prepared[0] as unknown[])[5], want, String(source));
  }
});

test('intake: ambiguous product -> clarification with options, nothing written', async () => {
  const { db, calls } = fakeDb();
  const out = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 10 }, { product_text: 'ORS', quantity: 6 }] },
    SENDER, db, 'test');
  assert.equal(out.status, 'needs_clarification');
  assert.deepEqual(out.status === 'needs_clarification' && out.questions, [
    { about: 'line', line: 2, text: 'ORS', problem: 'ambiguous',
      options: [{ id: 20, label: 'Meridian ORS Orange (21 g sachet)' }, { id: 21, label: 'Meridian ORS Lemon (21 g sachet)' }] },
  ]);
  assert.equal(calls.includes('prepare'), false);
});

test('intake: the rep\'s choice comes back as an id and is re-validated', async () => {
  const { db, prepared } = fakeDb();
  const out = await runIntake({ chemist_id: 10, lines: [{ product_text: 'Cetimer', quantity: 10 }, { product_id: 21, quantity: 6 }] }, SENDER, db, 't');
  assert.equal(out.status, 'ready');
  assert.deepEqual((prepared[0] as unknown[])[3], [{ product_id: 1, qty: 10, raw_text: 'Cetimer' }, { product_id: 21, qty: 6, raw_text: '' }]);
  // An id that is not the rep's chemist, or not an active product, is not trusted.
  const bad = await runIntake({ chemist_id: 99, lines: [{ product_id: 999, quantity: 1 }] }, SENDER, fakeDb().db, 't');
  assert.deepEqual(bad.status === 'needs_clarification' && bad.questions.map((q) => q.problem), ['not_yours', 'inactive_product']);
});

test('intake: unknown chemist (another rep\'s chemist) -> not found, nothing written', async () => {
  const { db, calls } = fakeDb();
  const out = await runIntake({ chemist_text: 'Sharma Medical Store', lines: [{ product_text: 'Cetimer', quantity: 10 }] }, SENDER, db, 't');
  assert.deepEqual(out.status === 'needs_clarification' && out.questions, [{ about: 'chemist', text: 'Sharma Medical Store', problem: 'not_found' }]);
  assert.equal(calls.includes('prepare'), false);
});

test('intake: bad or missing quantities and products are questions, not guesses', async () => {
  const { db, calls } = fakeDb();
  const out = await runIntake({ chemist_text: 'Singh Medical Agency',
    lines: [{ product_text: 'Cetimer', quantity: 2.5 }, { product_text: 'unobtainium', quantity: 1 }, { quantity: 3 }] }, SENDER, db, 't');
  assert.deepEqual(out.status === 'needs_clarification' && out.questions.map((q) => `${q.line}:${q.problem}`),
    ['1:invalid_quantity', '2:not_found', '3:missing']);
  assert.equal(calls.includes('prepare'), false);
  const empty = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [] }, SENDER, db, 't');
  assert.equal(empty.status, 'needs_clarification');
});

test('intake: refused without a verified rep, and nothing is looked up', async () => {
  const dev = senderContext({ channel: 'dev', requestChannel: 'dev', invoked: 'no', profile: {} });
  const { db, calls } = fakeDb();
  assert.deepEqual(await runIntake({ chemist_text: 'x', lines: [{ product_text: 'y', quantity: 1 }] }, dev, db, 't'), { status: 'refused', message: MSG_REFUSED });
  assert.deepEqual(calls, []);
  for (const who of [{ result: 'unknown_sender', user_id: null, role: null }, { result: 'ok', user_id: 5, role: 'area_manager' },
                     { result: 'ambiguous_sender', user_id: null, role: null }]) {
    const f = fakeDb({ identify: async () => who });
    const out = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 1 }] }, SENDER, f.db, 't');
    assert.deepEqual(out, { status: 'refused', message: MSG_REFUSED }, who.result);
    assert.equal(f.calls.some((x) => x.startsWith('chemist') || x === 'prepare'), false);
  }
});

test('intake: database failure or an incomplete summary -> generic error, no summary', async () => {
  const boom = fakeDb({ prepareOrder: async () => { throw new Error('postgresql://u:secret@h/db GUARD: x'); } });
  const out = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 1 }] }, SENDER, boom.db, 't');
  assert.deepEqual(out, { status: 'error', message: MSG_ERROR });
  const partial = fakeDb({ prepareOrder: async () => ({ order_id: 1, summary: sampleSummary({ confirmation: null }) }) });
  assert.deepEqual(await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'Cetimer', quantity: 1 }] }, SENDER, partial.db, 't'),
    { status: 'error', message: MSG_ERROR });
});

test('intake: with ids the rep chose, the rep\'s own words still go with the order (for alias learning)', async () => {
  const { db, prepared } = fakeDb();
  const out = await runIntake({ chemist_id: 10, chemist_text: 'singh bhai ki dukan',
    lines: [{ product_id: 21, product_text: 'संतरे वाला', quantity: 4 }] }, SENDER, db, 'test');
  assert.equal(out.status, 'ready');
  const args = prepared[0] as unknown[];
  assert.deepEqual(args[3], [{ product_id: 21, qty: 4, raw_text: 'संतरे वाला' }]);
  assert.equal(args[6], 'singh bhai ki dukan');
  // No words: nothing to learn, and nothing invented.
  const bare = fakeDb();
  await runIntake({ chemist_id: 10, lines: [{ product_id: 21, quantity: 4 }] }, SENDER, bare.db, 'test');
  assert.equal((bare.prepared[0] as unknown[])[6], '');
  assert.deepEqual((bare.prepared[0] as unknown[])[3], [{ product_id: 21, qty: 4, raw_text: '' }]);
});
