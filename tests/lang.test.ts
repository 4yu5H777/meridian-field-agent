// Unit tests: Hindi / English / mixed names and quantities.
//   node --test tests/lang.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { transliterate, stripFillers, nameVariants, numberFromWords, numbersIn, scriptOf, hasDevanagari } from '../src/lib/lang.ts';
import { runIntake, type Candidate, type IntakeDb } from '../src/lib/intake.ts';
import { senderContext } from '../src/lib/identity.ts';

test('transliteration: loanwords by dictionary, the rest phonetically, final schwa dropped', () => {
  for (const [hi, want] of [
    ['सिंह मेडिकल एजेंसी', 'singh medical agency'], ['ओआरएस ऑरेंज', 'ors orange'], ['शर्मा मेडिकोज', 'sharma medicos'],
    ['गुप्ता फार्मेसी', 'gupta pharmacy'], ['सेटिमर', 'setimar'], ['सेटीमर', 'setimar'], ['कफसेट', 'kafaset'],
    ['डॉलो', 'dolo'], ['ज़िंक', 'zink'], ['१० स्ट्रिप', '10 strip'], ['Cetimer सिरप', 'Cetimer syrup'],
  ]) assert.equal(transliterate(hi), want, hi);
  assert.equal(transliterate(''), '');
  assert.equal(hasDevanagari('abc'), false);
});

test('filler and pack words go, dosage forms are mapped but never dropped', () => {
  assert.equal(stripFillers('singh medical wale'), 'singh medical');
  assert.equal(stripFillers('ors ka orange wala'), 'ors orange');
  assert.equal(stripFillers('sharma ji ki dukaan'), 'sharma ji');
  assert.equal(stripFillers('सिंह मेडिकल वाले को'), 'सिंह मेडिकल');
  assert.equal(stripFillers('cetimer ke 10 patte bhej do'), 'cetimer 10');
  assert.equal(stripFillers('meridol 650 ki goli'), 'meridol 650 tablet');
  assert.equal(stripFillers('cetimer syrup ki shishi'), 'cetimer syrup');          // "syrup" stays: a different product
  assert.equal(stripFillers('पट्टी'), 'पट्टी');                                       // bandage, not a pack word
  assert.equal(stripFillers('Sharma Medical Store'), 'Sharma Medical Store');      // real name words stay
});

test('variants: as written first, then stripped, then transliterated; at most 3, no duplicates', () => {
  assert.deepEqual(nameVariants('Singh Medical Agency'), ['Singh Medical Agency']);
  assert.deepEqual(nameVariants('singh medical wale'), ['singh medical wale', 'singh medical']);
  assert.deepEqual(nameVariants('सिंह medical agency को'), ['सिंह medical agency को', 'सिंह medical agency', 'singh medical agency']);
  assert.deepEqual(nameVariants('   '), []);
  assert.deepEqual(nameVariants('ka'), ['ka']);                                    // nothing left after stripping: keep what was written
});

test('quantities in words: Hindi, Hinglish and English; anything vague is null', () => {
  for (const [t, want] of [['das', 10], ['दस', 10], ['बीस', 20], ['ek darjan', 12], ['do dozen', 24], ['दो दर्जन', 24], ['darjan', 12],
    ['das patta', 10], ['ten boxes', 10], ['pachees', 25], ['sau', 100],
    ['kuch', null], ['bahut saare', null], ['saath', null], ['das bees', null], ['10', null], ['', null]] as [string, number | null][]) {
    assert.equal(numberFromWords(t), want, t);
  }
});

test('script of a message', () => {
  assert.equal(scriptOf('सिंह मेडिकल को 10 सेटिमर भेजो'), 'hindi');
  assert.equal(scriptOf('singh medical ko das patta cetimer bhejo'), 'mixed');
  assert.equal(scriptOf('सिंह medical ko 10 Cetimer'), 'mixed');
  assert.equal(scriptOf('Send 10 Cetimer to Singh Medical Agency'), 'english');
});

// ------------------------------------------------------------------ intake with variants
const SENDER = senderContext({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: { emailAddresses: ['deepak.chauhan@meridian.example'] } });
const c = (id: number, name: string, score: number): Candidate => ({ id, name, detail: '', score, isRepAlias: false });

function db(table: Record<string, Candidate[]>) {
  const looked: string[] = [];
  const lookup = async (_r: number, text: string) => { looked.push(text); return table[text] ?? []; };
  const d: IntakeDb = {
    identify: async () => ({ result: 'ok', user_id: 42, role: 'rep' }),
    matchChemist: lookup, matchProduct: lookup,
    repChemist: async () => null, activeProduct: async () => null,
    prepareOrder: async () => { throw new Error('not in this test'); },
  };
  return { d, looked };
}

test('intake: each spelling is looked up, the best score per candidate counts, thresholds unchanged', async () => {
  const { d, looked } = db({
    'सिंह मेडिकल वाले को': [c(10, 'Singh Medical Agency', 0.55)],
    'सिंह मेडिकल': [c(10, 'Singh Medical Agency', 1)],                             // the stripped form hits the Hindi alias
    'ors ka orange wala': [c(20, 'Meridian ORS Orange', 0.53), c(21, 'Meridian ORS Lemon', 0.35)],
    'ors orange': [c(20, 'Meridian ORS Orange', 1)],
    'setimar': [], 'सेटिमर': [c(1, 'Cetimer 10 Tablet', 0.4)],                      // weak everywhere: must be asked
  });
  const r = await runIntake({ chemist_text: 'सिंह मेडिकल वाले को', lines: [{ product_text: 'ors ka orange wala', quantity: 6 }, { product_text: 'सेटिमर', quantity: 10 }] }, SENDER, d, 't');
  assert.equal(r.status, 'needs_clarification');
  const qs = (r as { questions: { about: string; line?: number; problem: string; text?: string; options?: { id: number }[] }[] }).questions;
  assert.deepEqual(qs.map((q) => [q.about, q.line ?? null, q.problem]), [['line', 2, 'ambiguous']]);   // chemist and ORS resolved, सेटिमर asked
  assert.equal(qs[0].text, 'सेटिमर');                                                // the rep's own words are quoted back
  assert.deepEqual(qs[0].options?.map((o) => o.id), [1]);
  assert.deepEqual(looked, ['सिंह मेडिकल वाले को', 'सिंह मेडिकल', 'singh medical', 'ors ka orange wala', 'ors orange', 'सेटिमर', 'setimar']);
});

test('intake: two candidates both strong after stripping stay ambiguous (never the first one)', async () => {
  const { d } = db({
    'meridol 650 ki goli': [c(3, 'Meridol 650 Tablet (10)', 0.6), c(4, 'Meridol 650 Tablet (15)', 0.6)],
    'meridol 650 tablet': [c(3, 'Meridol 650 Tablet (10)', 1), c(4, 'Meridol 650 Tablet (15)', 1)],
    'Singh Medical Agency': [c(10, 'Singh Medical Agency', 1)],
  });
  const r = await runIntake({ chemist_text: 'Singh Medical Agency', lines: [{ product_text: 'meridol 650 ki goli', quantity: 5 }] }, SENDER, d, 't');
  assert.equal(r.status, 'needs_clarification');
  assert.deepEqual((r as { questions: { problem: string; options?: { id: number }[] }[] }).questions.map((q) => [q.problem, q.options?.map((o) => o.id)]), [['ambiguous', [3, 4]]]);
});

test('numbers stated in a text, in any script or in words', () => {
  assert.deepEqual([...numbersIn('Cetimer, ten strips. And ORS orange, six.')].sort((a, b) => a - b), [6, 10]);
  assert.deepEqual([...numbersIn('das patta cetimer aur ek darjan ORS')].sort((a, b) => a - b), [1, 10, 12]);
  assert.deepEqual([...numbersIn('सेटीमर १० और छह ओआरएस')].sort((a, b) => a - b), [6, 10]);
  assert.equal(numbersIn('Cetimer ten').has(1), false);
});
