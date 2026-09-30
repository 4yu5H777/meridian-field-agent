// Unit tests: team_report request checks, error mapping, money formatting.
//   node --test tests/reports.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runReport, withRupees, MSG_REFUSED } from '../src/lib/reports.ts';
import { senderContext } from '../src/lib/identity.ts';

const VIKRAM = senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'no', profile: { mobileNumbers: ['+919000000002'] } });

function db(result: unknown) {
  const calls: unknown[][] = [];
  const query = async (...a: unknown[]) => { calls.push(a); if (result instanceof Error) throw result; return result; };
  return { calls, query };
}

test('withRupees adds an exact formatted string beside every paise number', () => {
  assert.deepEqual(withRupees({ value_paise: 1234500, reps: [{ value_paise: 5 }], n: 3, x_paise: 'nope' }),
    { value_paise: 1234500, value_rs: '₹12,345.00', reps: [{ value_paise: 5, value_rs: '₹0.05' }], n: 3, x_paise: 'nope' });
});

test('a verified sender gets the database answer, with rupees, and only fixed parameters go down', async () => {
  const d = db({ ok: true, report: 'orders_summary', data: { orders: 3, value_paise: 1234500 } });
  const r = await runReport({ report: 'orders_summary', period: 'last_7_days', rep: '  Ravi   ', area: '' }, VIKRAM, d.query);
  assert.equal(r.status, 'ok');
  assert.deepEqual((r as { answer: any }).answer.data, { orders: 3, value_paise: 1234500, value_rs: '₹12,345.00' });
  assert.deepEqual(d.calls, [['whatsapp', ['+919000000002'], 'orders_summary', { period: 'last_7_days', rep: 'Ravi' }]]);
});

test('no verified sender, no query', async () => {
  for (const s of [senderContext({ channel: 'dev', requestChannel: 'dev', invoked: 'no', profile: {} }),
                   senderContext({ channel: 'whatsapp', requestChannel: 'whatsapp', invoked: 'yes', profile: { mobileNumbers: ['+91900'] } })]) {
    const d = db({ ok: true });
    assert.deepEqual(await runReport({ report: 'orders_summary' }, s, d.query), { status: 'refused', message: MSG_REFUSED });
    assert.equal(d.calls.length, 0);
  }
});

test('only the fixed reports and periods; nothing free-form reaches the database', async () => {
  for (const input of [{ report: 'SELECT * FROM users' }, { report: 'orders_summary; DROP TABLE orders' }, { report: 'orders_summary', period: 'forever' }]) {
    const d = db({ ok: true });
    const r = await runReport(input, VIKRAM, d.query);
    assert.equal(r.status, 'invalid', JSON.stringify(input));
    assert.equal(d.calls.length, 0);
  }
  const long = db({ ok: true, data: {} });
  await runReport({ report: 'orders_summary', rep: 'x'.repeat(500), from: '2026-09-01T00:00:00Z' }, VIKRAM, long.query);
  const params = long.calls[0][3] as Record<string, string>;
  assert.equal(params.rep.length, 80);
  assert.equal(params.from, '2026-09-01');
});

test('database refusals map to fixed messages; nothing leaks', async () => {
  const cases: [unknown, string][] = [
    [{ ok: false, error: 'not_identified' }, 'refused'], [{ ok: false, error: 'rep_not_found' }, 'not_found'],
    [{ ok: false, error: 'area_not_found' }, 'not_found'], [{ ok: false, error: 'bad_period' }, 'invalid'],
    [{ ok: false, error: 'rep_required' }, 'invalid'], [{ ok: false, error: 'something new' }, 'error'], [null, 'error'],
    [new Error('postgresql://u:secret@h/db'), 'error'],
  ];
  for (const [res, want] of cases) {
    const r = await runReport({ report: 'rep_comparison', rep: 'Ravi' }, VIKRAM, db(res).query);
    assert.equal(r.status, want, JSON.stringify(res));
    assert.doesNotMatch(JSON.stringify(r), /secret|postgres/);
  }
  const amb = await runReport({ report: 'rep_comparison', rep: 'Ravi' }, VIKRAM, db({ ok: false, error: 'ambiguous_rep', candidates: ['Ravi Kumar', 'Ravi Verma'] }).query);
  assert.deepEqual(amb, { status: 'ambiguous', message: 'More than one rep matches; ask which one.', candidates: ['Ravi Kumar', 'Ravi Verma'] });
});
