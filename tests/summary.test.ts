// Unit tests for the canonical summary and the summary-integrity rules.
//   node --test tests/summary.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  renderSummary, checkSummary, enforceSummaryIntegrity, fourDigitTokens, hasConfirmInstruction, mightCarryOrderData,
  SUMMARY_UNAVAILABLE, SUMMARY_NOT_VALID, type LiveSummaryRow, type IntegrityDb,
} from '../src/lib/summary.ts';
import { senderContext } from '../src/lib/identity.ts';
import { sampleSummary } from './fixtures.ts';

const SENDER = senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'no', profile: { mobileNumbers: ['+919000000042'] } });

function fakeDb(rows: LiveSummaryRow[] | Error | 'hang', markResult: number | Error = 1) {
  const marked: number[][] = [];
  const db: IntegrityDb = {
    liveSummaries: async () => {
      if (rows === 'hang') return new Promise<never>(() => {});
      if (rows instanceof Error) throw rows;
      return rows;
    },
    markDelivered: async (_c, _k, ids) => { marked.push(ids); if (markResult instanceof Error) throw markResult; return markResult; },
  };
  return { db, marked };
}
const row = (over: Partial<LiveSummaryRow> = {}): LiveSummaryRow =>
  ({ confirmation_id: '76', order_id: '81', code: '3867', delivered: false, summary: sampleSummary(), ...over });
const run = (response: string, db: IntegrityDb, sender = SENDER) => enforceSummaryIntegrity({ response, sender, db, timeoutMs: 100 });

test('renderSummary: every figure comes from the data, formatted, nothing computed', () => {
  assert.equal(renderSummary(sampleSummary()), [
    'Order #81 for Singh Medical Agency, Sector 18',
    '1. Cetimer 10 Tablet (strip of 10) x 10 @ ₹20.00 = ₹190.00',
    '   Cetimer 10: 5% off: ₹200.00 less ₹10.00',
    '2. Meridian ORS Orange (21 g sachet) x 6 @ ₹22.00 = ₹132.00',
    '   ORS Orange: buy 2 get 1 free: 3 free',
    'Total: ₹322.00',
    'To confirm, reply exactly: YES 3867 (valid until 14:09 IST).',
  ].join('\n'));
});

test('renderSummary: off-route, over-limit and duplicate warnings', () => {
  const text = renderSummary(sampleSummary({
    is_off_route: true,
    credit: { limit_paise: 5000000, owed_paise: 611500, over_limit: true, manager_name: 'Kavita Srivastava' },
    duplicate: { order_id: 80, status: 'confirmed', at_ist: '13:05' },
  }));
  assert.match(text, /Note: Singh Medical Agency is not on today's route\. That is allowed/);
  assert.match(text, /over its limit of ₹50,000\.00 \(already owed ₹6,115\.00\)\. If you confirm, it goes to Kavita Srivastava for approval/);
  assert.match(text, /repeat of order #80 placed at 13:05/);
  assert.ok(text.endsWith('To confirm, reply exactly: YES 3867 (valid until 14:09 IST).'));
});

test('checkSummary: incomplete or inconsistent data is refused, never filled in', () => {
  const bad: Record<string, unknown>[] = [
    { status: 'confirmed' }, { status: 'cancelled' }, { lines: [] }, { total_paise: 0 }, { total_paise: '32200' },
    { chemist: { name: 'X' } }, { is_off_route: 'no' }, { confirmation: null },
    { confirmation: { code: '38', total_paise: 32200, expires_ist: '14:09' } },
    { confirmation: { code: '3867', total_paise: 99, expires_ist: '14:09' } },       // code frozen at another total
    { confirmation: { code: '3867', total_paise: 32200, expires_ist: 'soon' } },
    { credit: { limit_paise: 1, owed_paise: 1, over_limit: 'yes', manager_name: 'K' } },
    { duplicate: { order_id: 'x', at_ist: '13:05' } },
    { lines: [{ line_no: 1, product: 'X', pack: 'p', qty: 1, unit_price_paise: 1.5, gross_paise: 1, free_qty: 0, discount_paise: 0, line_total_paise: 1, scheme: null }] },
  ];
  for (const over of bad) assert.throws(() => checkSummary(sampleSummary(over)), /summary data invalid/, JSON.stringify(over));
  assert.throws(() => checkSummary(null));
  assert.throws(() => checkSummary('text'));
});

test('token helpers', () => {
  assert.deepEqual(fourDigitTokens('YES 3867 by 14:09, order 81, pin 12345'), ['3867']);
  assert.deepEqual(fourDigitTokens('हाँ ३८६७'), ['3867']);
  assert.equal(hasConfirmInstruction('Reply YES 3867 to confirm'), true);
  assert.equal(hasConfirmInstruction('reply *YES 3867*'), true);
  assert.equal(hasConfirmInstruction('haan ३८६७'), true);
  assert.equal(hasConfirmInstruction('Your order #81 is ready'), false);
  assert.equal(mightCarryOrderData('Total ₹322.00'), true);
  assert.equal(mightCarryOrderData('total Rs 322'), true);
  assert.equal(mightCarryOrderData('Hello Deepak, which chemist?'), false);
});

test('integrity: an undelivered summary replaces whatever the model wrote, and is marked delivered', async () => {
  const { db, marked } = fakeDb([row()]);
  const out = await run('Your order total is ₹300. Reply YES 3867.', db);   // model got the total wrong
  assert.equal(out.text, renderSummary(sampleSummary()));
  assert.deepEqual(marked, [[76]]);
  // ...even when the model left the code out entirely.
  const again = await run('Order placed!', fakeDb([row()]).db);
  assert.equal(again.text, renderSummary(sampleSummary()));
});

test('integrity: if marking fails, the canonical summary is still what is sent', async () => {
  const out = await run('anything', fakeDb([row()], new Error('db')).db);
  assert.equal(out.text, renderSummary(sampleSummary()));
  assert.match(out.log, /not marked/);
});

test('integrity: a delivered summary is re-shown canonically when its live code is mentioned', async () => {
  const out = await run('Sure, again: order 81, total ₹999, reply YES 3867', fakeDb([row({ delivered: true })]).db);
  assert.equal(out.text, renderSummary(sampleSummary()));
  const hindi = await run('हाँ ३८६७ लिखें', fakeDb([row({ delivered: true })]).db);
  assert.equal(hindi.text, renderSummary(sampleSummary()));
});

test('integrity: a confirm instruction with a code that is not live is withheld', async () => {
  const out = await run('Reply YES 1234 to confirm your order', fakeDb([row({ delivered: true })]).db);
  assert.equal(out.text, SUMMARY_NOT_VALID);
  const none = await run('Reply YES 3867 to confirm', fakeDb([]).db);     // nothing live for this rep (other rep's / expired)
  assert.equal(none.text, SUMMARY_NOT_VALID);
});

test('integrity: ordinary replies pass through untouched', async () => {
  const msg = 'Which chemist is this for: Singh Medical Agency or Arogya Pharmacy?';
  assert.equal((await run(msg, fakeDb([row({ delivered: true })]).db)).text, msg);
  assert.equal((await run(msg, fakeDb([]).db)).text, msg);
});

test('integrity: database error or timeout withholds anything that might carry order data', async () => {
  assert.equal((await run('Total ₹322.00, reply YES 3867', fakeDb(new Error('down')).db)).text, SUMMARY_UNAVAILABLE);
  assert.equal((await run('Total ₹322.00', fakeDb('hang').db)).text, SUMMARY_UNAVAILABLE);
  assert.equal((await run('Order 3867 ok', fakeDb(new Error('down')).db)).text, SUMMARY_UNAVAILABLE);
  const plain = 'Which chemist is this for?';
  assert.equal((await run(plain, fakeDb(new Error('down')).db)).text, plain);
});

test('integrity: malformed summary data is never shown', async () => {
  const out = await run('whatever', fakeDb([row({ summary: sampleSummary({ total_paise: null }) })]).db);
  assert.equal(out.text, SUMMARY_UNAVAILABLE);
  const notArray = await run('Total ₹5', { liveSummaries: async () => 'rows' as unknown as LiveSummaryRow[], markDelivered: async () => 0 });
  assert.equal(notArray.text, SUMMARY_UNAVAILABLE);
});

test('integrity: no verified sender (wrong channel, invoked, no contacts)', async () => {
  const dev = senderContext({ channel: 'dev', requestChannel: 'dev', invoked: 'no', profile: {} });
  const invoked = senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'yes', profile: { mobileNumbers: ['+919000000042'] } });
  const nobody = senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'no', profile: { mobileNumbers: [] } });
  const { db, marked } = fakeDb([row()]);
  for (const s of [dev, invoked, nobody]) {
    assert.equal((await run('Reply YES 3867', db, s)).text, SUMMARY_NOT_VALID);
    assert.equal((await run('Hello!', db, s)).text, 'Hello!');
  }
  assert.equal(marked.length, 0);
});

test('senderContext rules', () => {
  const p = { mobileNumbers: ['+919000000042'], emailAddresses: ['d@x.example'] };
  assert.deepEqual(senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'no', profile: p }),
    { ok: true, channel: 'whatsapp', contacts: ['+919000000042'] });
  assert.deepEqual(senderContext({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: p }),
    { ok: true, channel: 'email', contacts: ['d@x.example'] });
  assert.deepEqual(senderContext({ channel: 'whatsapp', requestChannel: 'email', invoked: 'no', profile: p }), { ok: false, reason: 'channel_mismatch' });
  assert.deepEqual(senderContext({ channel: 'whatsapp', requestChannel: undefined, invoked: 'no', profile: p }), { ok: false, reason: 'channel_mismatch' });
  assert.deepEqual(senderContext({ channel: 'dev', requestChannel: 'dev', invoked: 'no', profile: p }), { ok: false, reason: 'wrong_channel' });
  assert.deepEqual(senderContext({ channel: undefined, requestChannel: undefined, invoked: 'no', profile: p }), { ok: false, reason: 'wrong_channel' });
  assert.deepEqual(senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'unknown', profile: p }), { ok: false, reason: 'invoked' });
  assert.deepEqual(senderContext({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: { mobileNumbers: ['+91'] } }), { ok: false, reason: 'no_contacts' });
});
