// Unit tests: the 7 PM evening email and its schedule.
//   node --test tests/evening.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderEveningSummary, formatDate, EVENING_SUMMARY_SCHEDULE } from '../src/lib/eveningSummary.ts';
import { renderNotification } from '../src/lib/notify.ts';

const manager = (over: Record<string, unknown> = {}) => ({
  date: '2026-09-29',
  viewer: { id: 2, name: 'Vikram Malhotra', role: 'area_manager', area: 'North Delhi' },
  team: { reps: 3, orders: 3, value_paise: 1234500, off_route: 1, by_status: { submitted: 2, awaiting_credit_approval: 1 } },
  reps: [
    { name: 'Ravi Kumar', code: 'REP-NDL-01', area: 'North Delhi', orders: 2, value_paise: 1234500, off_route: 0 },
    { name: 'Imran Qureshi', code: 'REP-NDL-02', area: 'North Delhi', orders: 1, value_paise: 0, off_route: 1 },
    { name: 'Amit Sharma', code: 'REP-NDL-03', area: 'North Delhi', orders: 0, value_paise: 0, off_route: 0 },
  ],
  waiting: [{ token: 'CR-1A2B3C4D', order_id: 64, rep: 'Imran Qureshi', chemist: 'Jain Medicos', total_paise: 1538000,
              over_by_paise: 839000, requested_ist: '29 Sep 11:20', manager: 'Vikram Malhotra' }],
  off_route_orders: [{ order_id: 64, rep: 'Imran Qureshi', chemist: 'Jain Medicos', total_paise: 1538000, status: 'awaiting_credit_approval' }],
  ...over,
});

test('schedule: every day at 19:00 India time', () => {
  assert.deepEqual(EVENING_SUMMARY_SCHEDULE, { type: 'cron', expression: '0 19 * * *', timezone: 'Asia/Kolkata' });
});

test('dates', () => {
  assert.equal(formatDate('2026-09-29'), '29 Sep 2026');
  assert.equal(formatDate('2026-01-05'), '5 Jan 2026');
  for (const bad of ['2026-13-01', '29/09/2026', '', null]) assert.throws(() => formatDate(bad));
});

test('manager email: every figure from the payload, formatted', () => {
  const { subject, text } = renderEveningSummary(manager());
  assert.equal(subject, 'Meridian evening summary for 29 Sep 2026: North Delhi');
  for (const s of [
    'Dear Vikram Malhotra,',
    'Your team\'s orders on 29 Sep 2026 (North Delhi, 3 reps):',
    'Orders confirmed: 3   Value: ₹12,345.00   Off route: 1',
    'By status: awaiting credit approval 1, sent to distributor 2',
    '- Ravi Kumar: 2 orders, ₹12,345.00',
    '- Imran Qureshi: 1 order, ₹0.00, 1 off route',
    '- No orders today: Amit Sharma',
    'Waiting on you (credit approval):',
    '- Order #64, Jain Medicos (Imran Qureshi): ₹15,380.00, over the limit by ₹8,390.00. Requested 29 Sep 11:20. Reply to the approval email [CR-1A2B3C4D].',
    '- Order #64, Jain Medicos (Imran Qureshi): ₹15,380.00, awaiting credit approval',
  ]) assert.ok(text.includes(s), s);
});

test('empty team: clean, explicit, no invented figures', () => {
  const { text } = renderEveningSummary(manager({
    viewer: { id: 5, name: 'Sunita Arora', role: 'area_manager', area: 'West Delhi' },
    team: { reps: 6, orders: 0, value_paise: 0, off_route: 0, by_status: {} },
    reps: [{ name: 'Manish Sethi', orders: 0, value_paise: 0, off_route: 0 }], waiting: [], off_route_orders: [] }));
  assert.ok(text.includes('No orders from your team today.'));
  assert.ok(text.includes('Nothing is waiting on you.'));
  assert.ok(text.includes('No off-route orders today.'));
  assert.ok(!text.includes('₹'));
});

test('regional head: all teams, rep areas, who each approval waits on', () => {
  const { subject, text } = renderEveningSummary(manager({ viewer: { id: 1, name: 'Anjali Mehra', role: 'regional_head', area: null } }));
  assert.equal(subject, 'Meridian evening summary for 29 Sep 2026: all teams');
  assert.ok(text.includes('Orders across all teams on 29 Sep 2026 (all teams, 3 reps):'));
  assert.ok(text.includes('- Ravi Kumar (North Delhi): 2 orders'));
  assert.ok(text.includes('Waiting on area managers (credit approval):'));
  assert.ok(text.includes('With Vikram Malhotra.'));
});

test('incomplete data is refused, never guessed', () => {
  for (const over of [{ date: 'today' }, { viewer: { name: 'X', role: 'rep', area: 'A' } }, { team: { reps: 1, orders: '3', value_paise: 0, off_route: 0, by_status: {} } },
                      { reps: null }, { waiting: [{ order_id: 1 }] }, { off_route_orders: [{ order_id: 1, total_paise: -5 }] }]) {
    assert.throws(() => renderEveningSummary(manager(over)), /summary data invalid/, JSON.stringify(over));
  }
});

test('the dispatcher renders it as an email', () => {
  const m = renderNotification({ id: '1', kind: 'evening_summary', channel: 'email', address: 'vikram.malhotra@meridian.example', payload: manager() });
  assert.equal(m.subject, 'Meridian evening summary for 29 Sep 2026: North Delhi');
  assert.ok(m.text.startsWith('Dear Vikram Malhotra,'));
});
