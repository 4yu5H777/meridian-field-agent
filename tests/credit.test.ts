// Unit tests: notification wording, the dispatcher loop, and manager replies.
//   node --test tests/credit.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderNotification, dispatchNotifications, type ClaimedNotification, type OutgoingMessage } from '../src/lib/notify.ts';
import { findTokens, parseDecision, handleCreditReply, REPLY_USE_EMAIL, REPLY_NOT_YOURS, REPLY_HOW, REPLY_ONE_AT_A_TIME, REPLY_ERROR } from '../src/lib/creditReply.ts';

const approvalPayload = (over: Record<string, unknown> = {}) => ({
  approval_id: 7, token: 'CR-1A2B3C4D', order_id: 90, manager_name: 'Kavita Srivastava', rep_name: 'Deepak Chauhan',
  chemist: { code: 'CH-12', name: 'Om Sai Medicos', locality: 'Sector 50' },
  order_total_paise: 5400000, owed_paise: 611500, limit_paise: 5000000, over_by_paise: 1011500,
  lines: [{ line_no: 1, product: 'Multimer Daily Tablet', pack: 'strip of 15', qty: 300, unit_price_paise: 18000,
            gross_paise: 5400000, free_qty: 0, discount_paise: 0, line_total_paise: 5400000, scheme: null }],
  ...over,
});
const approvalRow = (over: Partial<ClaimedNotification> = {}): ClaimedNotification =>
  ({ id: '11', kind: 'credit_approval_request', channel: 'email', address: 'kavita.srivastava@meridian.example', payload: approvalPayload(), ...over });
const decisionRow = (decision: string, note = ''): ClaimedNotification => ({
  id: '12', kind: 'credit_decision_to_rep', channel: 'whatsapp', address: '+919000000042',
  payload: { approval_id: 7, token: 'CR-1A2B3C4D', order_id: 90, decision, manager_name: 'Kavita Srivastava',
             chemist_name: 'Om Sai Medicos', order_total_paise: 5400000, note },
});

test('approval email: token in subject, every figure from the payload, how to reply', () => {
  const m = renderNotification(approvalRow());
  assert.equal(m.channel, 'email');
  assert.equal(m.address, 'kavita.srivastava@meridian.example');
  assert.equal(m.subject, 'Credit approval needed: order #90 for Om Sai Medicos [CR-1A2B3C4D]');
  for (const s of ['1. Multimer Daily Tablet (strip of 15) x 300 @ ₹180.00 = ₹54,000.00', 'Order total:       ₹54,000.00',
                   'Already owed:      ₹6,115.00', 'Credit limit:      ₹50,000.00', 'Over the limit by: ₹10,115.00',
                   'APPROVE or REJECT as the first line', 'applies to order #90 only']) {
    assert.ok(m.text.includes(s), s);
  }
});

test('approval email: refused unless complete, well-typed and by email', () => {
  for (const over of [{ token: 'CR-XYZ' }, { order_total_paise: '5400000' }, { over_by_paise: null }, { lines: [] }, { chemist: null }]) {
    assert.throws(() => renderNotification(approvalRow({ payload: approvalPayload(over) })), /summary data invalid/, JSON.stringify(over));
  }
  assert.throws(() => renderNotification(approvalRow({ channel: 'whatsapp', address: '+919000000037' })), /by email/);
  assert.throws(() => renderNotification(approvalRow({ address: '' })), /address/);
  assert.throws(() => renderNotification(approvalRow({ kind: 'something_else' })), /unknown kind/);
});

test('decision to the rep', () => {
  assert.equal(renderNotification(decisionRow('approved')).text,
    'Order #90 for Om Sai Medicos (₹54,000.00) was approved by Kavita Srivastava. It will now be sent to the distributor.');
  assert.equal(renderNotification(decisionRow('rejected', 'Collect payment first.')).text,
    'Order #90 for Om Sai Medicos (₹54,000.00) was NOT approved by Kavita Srivastava. Nothing was sent to the distributor. Note from Kavita Srivastava: "Collect payment first."');
  assert.equal(renderNotification({ ...decisionRow('approved'), channel: 'email', address: 'd@x.example' }).subject, 'Order #90: credit approved');
  assert.throws(() => renderNotification(decisionRow('maybe')));
});

test('dispatcher: sends, records, retries failures, never throws', async () => {
  const sent: OutgoingMessage[] = []; const done: [number, string][] = []; const failed: [number, string][] = [];
  const base = { complete: async (id: number, ref: string) => { done.push([id, ref]); }, fail: async (id: number, e: string) => { failed.push([id, e]); },
                 limit: 10, sendTimeoutMs: 50 };
  const r1 = await dispatchNotifications({ ...base, claim: async () => [approvalRow(), decisionRow('approved')],
    send: async (m) => { sent.push(m); return { ref: `ref-${sent.length}` }; } });
  assert.deepEqual(r1, { claimed: 2, sent: 2, failed: 0 });
  assert.deepEqual(done, [[11, 'ref-1'], [12, 'ref-2']]);

  // A send error, a hanging send, bad data, a bad id: each is failed, the rest still go.
  done.length = 0;
  const r2 = await dispatchNotifications({ ...base,
    claim: async () => [{ ...decisionRow('approved'), id: '21' }, { ...decisionRow('approved'), id: '22' },
                        approvalRow({ id: '23', payload: approvalPayload({ token: 'bad' }) }), { ...decisionRow('approved'), id: 'x' },
                        { ...decisionRow('rejected'), id: '24' }],
    send: async (m) => {
      if (m.text.includes('NOT approved')) return { ref: 'ok-24' };
      if (sent.length++ === 2) throw new Error('postgresql://u:secret@h/db provider down');
      return new Promise<never>(() => {});
    } });
  assert.deepEqual(r2, { claimed: 5, sent: 1, failed: 4 });
  assert.deepEqual(done, [[24, 'ok-24']]);
  assert.ok(failed.every(([, e]) => !/secret|postgres/.test(e)));
  assert.deepEqual(await dispatchNotifications({ ...base, claim: async () => { throw new Error('db down'); }, send: async () => ({ ref: '' }) }),
    { claimed: 0, sent: 0, failed: 0, error: 'claim failed (Error)' });
});

test('tokens and decisions', () => {
  assert.deepEqual(findTokens('Re: Credit approval needed [cr-1a2b3c4d] and CR-1A2B3C4D'), ['CR-1A2B3C4D']);
  assert.deepEqual(findTokens('CR-12345678 CR-87654321'), ['CR-12345678', 'CR-87654321']);
  assert.deepEqual(findTokens('XCR-12345678 CR-1234567'), []);
  const yes = ['APPROVE', 'Approved.', 'ok', 'OK thanks', 'yes please', 'haan'];
  const no = ['REJECT collect the pending payment first', 'Rejected', 'No.', 'No, collect first', 'no', 'nahi'];
  for (const t of yes) assert.equal(parseDecision(`${t}\n\nOn Tue, Meridian wrote:\n> Reply APPROVE or REJECT`)?.decision, 'approved', t);
  for (const t of no) assert.equal(parseDecision(t)?.decision, 'rejected', t);
  assert.equal(parseDecision('REJECT collect the pending payment first')?.note, 'collect the pending payment first');
  for (const t of ['no problem, approved', 'please call me', 'maybe tomorrow', '', '> APPROVE', 'approve-ish? no: reject', 'okayish']) {
    assert.equal(parseDecision(t), null, t);
  }
});

const KAVITA = { emailAddresses: ['kavita.srivastava@meridian.example'] };
const reply = (over: Partial<Parameters<typeof handleCreditReply>[0]> = {}) => {
  const calls: unknown[][] = [];
  const decide = async (...a: unknown[]) => { calls.push(a); return 'approved'; };
  return { calls, run: handleCreditReply({ messages: [{ type: 'text', text: 'APPROVE\n\n> old text' }], subject: 'Re: Credit approval needed: order #90 [CR-1A2B3C4D]',
    channel: 'email', requestChannel: 'email', invoked: 'no', profile: KAVITA, decide, timeoutMs: 100, ...over }) };
};

test('reply: identity from the profile, token from the subject, decision from the first line', async () => {
  const r = reply();
  assert.deepEqual(await r.run, { action: 'block', response: 'Approved (CR-1A2B3C4D). The order will be sent to the distributor and the rep has been told.',
                                  log: 'CR-1A2B3C4D approved: approved', decided: true });
  assert.deepEqual(r.calls, [[['kavita.srivastava@meridian.example'], 'CR-1A2B3C4D', 'approved', 'APPROVE']]);
});

test('reply: messages with no approval reference go to the model untouched', async () => {
  const r = reply({ subject: 'Question about sales', messages: [{ type: 'text', text: 'How many orders today?' }] });
  assert.deepEqual(await r.run, { action: 'proceed' });
  assert.equal(r.calls.length, 0);
});

test('reply: approval references outside an email reply never decide anything', async () => {
  for (const over of [{ channel: 'whatsapp', requestChannel: 'whatsapp' }, { channel: 'dev', requestChannel: 'dev' },
                      { requestChannel: 'whatsapp' }, { invoked: 'yes' as const }, { invoked: 'unknown' as const }]) {
    const r = reply(over);
    const out = await r.run;
    assert.equal(out.action === 'block' && out.response, REPLY_USE_EMAIL, JSON.stringify(over));
    assert.equal(r.calls.length, 0);
  }
});

test('reply: unclear replies are asked again, not guessed', async () => {
  const cases: [Partial<Parameters<typeof handleCreditReply>[0]>, string][] = [
    [{ messages: [{ type: 'text', text: 'no problem, will check' }] }, REPLY_HOW],
    [{ subject: 'Re: [CR-1A2B3C4D] and [CR-99999999]' }, REPLY_ONE_AT_A_TIME],
    [{ subject: undefined, messages: [{ type: 'text', text: 'APPROVE\n> CR-1A2B3C4D\n> CR-99999999' }] }, REPLY_ONE_AT_A_TIME],
  ];
  for (const [over, want] of cases) {
    const r = reply(over);
    const out = await r.run;
    assert.equal(out.action === 'block' && out.response, want);
    assert.equal(r.calls.length, 0);
  }
  // Token only in the quoted body (subject lost): still bound to that one request.
  const q = reply({ subject: 'Re: your email', messages: [{ type: 'text', text: 'REJECT\n> Keep CR-1A2B3C4D in the subject' }] });
  await q.run;
  assert.deepEqual(q.calls[0].slice(1, 3), ['CR-1A2B3C4D', 'rejected']);
});

test('reply: the database decides; every refusal is a fixed reply', async () => {
  for (const [result, want] of [['not_authorized', REPLY_NOT_YOURS], ['already_decided', 'CR-1A2B3C4D was already decided or is no longer waiting. Nothing was changed.'],
                                ['not_found', 'No approval request matches CR-1A2B3C4D.'], ['rejected', /^Rejected \(CR-1A2B3C4D\)/], ['something odd', REPLY_ERROR]] as const) {
    const out = await handleCreditReply({ messages: [{ type: 'text', text: 'APPROVE' }], subject: '[CR-1A2B3C4D]', channel: 'email', requestChannel: 'email',
      invoked: 'no', profile: KAVITA, decide: async () => result, timeoutMs: 100 });
    assert.ok(out.action === 'block');
    if (typeof want === 'string') assert.equal(out.response, want); else assert.match(out.response, want);
    assert.equal(out.decided, result === 'rejected');
  }
  const hang = await handleCreditReply({ messages: [{ type: 'text', text: 'APPROVE' }], subject: '[CR-1A2B3C4D]', channel: 'email', requestChannel: 'email',
    invoked: 'no', profile: KAVITA, decide: () => new Promise<never>(() => {}), timeoutMs: 30 });
  assert.deepEqual(hang, { action: 'block', response: REPLY_ERROR, log: 'CR-1A2B3C4D: database call failed', decided: false });
  // A missing profile sends no contacts; the database refuses (tested in db/checks-credit.sql).
  const calls: unknown[][] = [];
  await handleCreditReply({ messages: [{ type: 'text', text: 'APPROVE' }], subject: '[CR-1A2B3C4D]', channel: 'email', requestChannel: 'email',
    invoked: 'no', profile: undefined, decide: async (...a) => { calls.push(a); return 'not_authorized'; }, timeoutMs: 100 });
  assert.deepEqual(calls[0][0], []);
});

