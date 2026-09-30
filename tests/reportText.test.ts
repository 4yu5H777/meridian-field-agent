// Unit tests: a manager's numbers are the report's numbers, or the reply is replaced.
//   node --test tests/reportText.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderReport, allowedNumbers, unsupportedNumbers, checkReportReply, GUARD_TTL_MS } from '../src/lib/reportText.ts';
import { runReport } from '../src/lib/reports.ts';
import { senderContext } from '../src/lib/identity.ts';

const RAVI = {
  ok: true, report: 'rep_comparison', scope: 'all teams', rep_filter: 'Ravi Kumar',
  period: { name: 'last_7_days', from: '2026-09-23', to: '2026-09-29' },
  data: { rep: 'Ravi Kumar', change_orders: -2, change_value_paise: -1760400,
    current: { from: '2026-09-23', to: '2026-09-29', orders: 2, off_route: 0, value_paise: 166000, credit_rejected: 1, distributor_rejected: 0 },
    previous: { from: '2026-09-16', to: '2026-09-22', orders: 4, off_route: 1, value_paise: 1926400, credit_rejected: 0, distributor_rejected: 0 } },
};
const NORTH = { ok: true, report: 'over_limit_chemists', scope: 'own team', period: {},
  data: { count: 1, chemists: [{ area: 'North Delhi', chemist: 'New Life Chemists', owed_paise: 11725500, limit_paise: 10000000, over_by_paise: 1725500 }] } };
const TEAM = { ok: true, report: 'orders_summary', scope: 'own team', period: { from: '2026-09-23', to: '2026-09-29' },
  data: { orders: 6, value_paise: 2301450, off_route: 1, by_status: { dispatched: 2, awaiting_credit_approval: 1 },
    reps: [{ name: 'Imran Qureshi', orders: 4, off_route: 1, value_paise: 2135450 }, { name: 'Ravi Kumar', orders: 2, off_route: 0, value_paise: 166000 }], reps_without_orders: 5 } };

test('answers are rendered from the report, amounts in Indian rupee format', () => {
  assert.equal(renderReport(RAVI), [
    'Ravi Kumar: 2026-09-23 to 2026-09-29 compared with 2026-09-16 to 2026-09-22.',
    'Orders: 2 vs 4 (-2).',
    'Value: ₹1,660.00 vs ₹19,264.00 (-₹17,604.00).',
    'Off route: 0 vs 1. Credit rejected: 1 vs 0. Rejected by the distributor: 0 vs 0.'].join('\n'));
  assert.equal(renderReport(NORTH), 'Chemists over their credit limit, own team: 1.\n- New Life Chemists (North Delhi): owes ₹1,17,255.00 against a limit of ₹1,00,000.00, over by ₹17,255.00');
  assert.match(renderReport(TEAM), /^Orders \(2026-09-23 to 2026-09-29\), own team:\n6 orders worth ₹23,014.50; 1 off route\.\nBy status: dispatched 2, awaiting credit approval 1\.\n- Imran Qureshi: 4 orders, ₹21,354.50, 1 off route\n- Ravi Kumar: 2 orders, ₹1,660.00, 0 off route\nReps with no orders: 5\.$/);
  assert.equal(renderReport(null), 'No figures.');
});

test('a reply that restates the figures, in any common form, passes', () => {
  const allowed = allowedNumbers(RAVI);
  for (const reply of [
    renderReport(RAVI),
    'Ravi is down: 2 orders this week against 4 last week, ₹1,660.00 vs ₹19,264.00 — ₹17,604 less.',
    'Ravi Kumar had 2 orders worth Rs 1660 (previous 7 days: 4 orders, Rs. 19,264). One was credit rejected.',
    'Summary:\n1. Orders: 2 vs 4\n2. Value: ₹1,660 vs ₹19,264',                  // list markers are not figures
    'From 23 Sep to 29 Sep 2026 Ravi placed 2 orders.',                         // dates from the report
    'Nothing numeric to add.',
  ]) assert.deepEqual(unsupportedNumbers(reply, allowed), [], reply);
});

test('any figure the report does not contain is caught', () => {
  const allowed = allowedNumbers(RAVI);
  for (const [reply, why] of [
    ['Ravi is down 50% this week.', 'a percentage the model computed'],
    ['Ravi had 3 orders this week.', 'a wrong count'],
    ['Ravi and the team together did 6 orders.', 'a sum'],
    ['Value fell to about ₹1,700.', 'a rounding'],
    ['Ravi sold ₹1,66,000 this week.', 'paise read as rupees (100x)'],
    ['Ravi sold ₹16.60 this week.', 'rupees read as paise'],
    ['Ravi averaged ₹830 per order.', 'an average'],
    ['Ravi is 2 orders down, worth ₹17,605.', 'an off-by-one amount'],
  ] as const) assert.notDeepEqual(unsupportedNumbers(reply, allowed), [], why);
  const north = allowedNumbers(NORTH);
  assert.deepEqual(unsupportedNumbers('New Life owes ₹1,17,255 against ₹1,00,000 — ₹17,255 over.', north), []);
  assert.notDeepEqual(unsupportedNumbers('New Life owes ₹1,17,255, which is 17% over.', north), []);
});

test('the postprocessor decision: one use, ten minutes, order summaries left alone', () => {
  const now = 1_800_000_000_000;
  const guard = { at: now - 1000, text: renderReport(RAVI), allowed: allowedNumbers(RAVI) };
  assert.deepEqual(checkReportReply('Hi Vikram!', undefined, now), { text: 'Hi Vikram!', consume: false, log: 'no report this turn' });
  assert.deepEqual(checkReportReply('Ravi had 2 orders.', guard, now), { text: 'Ravi had 2 orders.', consume: true, log: 'numbers match the report' });
  const bad = checkReportReply('Ravi is down 50%.', guard, now);
  assert.deepEqual([bad.text, bad.consume], [guard.text, true]);
  assert.match(bad.log, /^replaced: 1 number/);
  assert.equal(checkReportReply('Ravi is down 50%.', { ...guard, at: now - GUARD_TTL_MS - 1 }, now).text, 'Ravi is down 50%.');   // stale: not this turn's
  assert.equal(checkReportReply('Reply YES 4821 to confirm. Total ₹99', guard, now).text, 'Reply YES 4821 to confirm. Total ₹99');
  for (const junk of [null, 'x', { text: 1, allowed: [], at: now }, { text: 't', allowed: 'no', at: now }, { text: 't', allowed: [] }]) {
    assert.equal(checkReportReply('any 123', junk, now).consume, false);
  }
});

test('team_report returns answer_text plus the guard; the model is told its numbers are checked', async () => {
  const vikram = senderContext({ channel: 'email', requestChannel: 'email', invoked: 'no', profile: { emailAddresses: ['vikram.malhotra@meridian.example'] } });
  const r = await runReport({ report: 'over_limit_chemists', area: 'north' }, vikram, async () => NORTH) as { status: string; answer_text: string; message: string; guard: { text: string; allowed: string[] } };
  assert.equal(r.status, 'ok');
  assert.equal(r.answer_text, renderReport(NORTH));
  assert.equal(r.guard.text, r.answer_text);
  assert.deepEqual(unsupportedNumbers(r.answer_text, r.guard.allowed), []);
  assert.match(r.message, /replaced by answer_text/);
});
