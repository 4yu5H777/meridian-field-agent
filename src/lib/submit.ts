// Sending confirmed orders to the distributor. Pure, so it can be unit-tested;
// the database and the HTTP call are passed in.
//
// The database decides WHICH orders may go (claim_submissions only returns
// orders the order guard would let through right now) and records the result
// (submit_order: idempotent, guard re-checked). This loop only carries the
// payload to the distributor and the distributor's reference back.
export type ClaimedSubmission = { order_id: unknown; idempotency_key: unknown; attempts?: unknown; payload: unknown };

export type SubmitDeps = {
  claim: (limit: number) => Promise<ClaimedSubmission[]>;
  send: (payload: unknown, idempotencyKey: string) => Promise<{ distributor_ref: string }>;
  record: (orderId: number, idempotencyKey: string, distributorRef: string) => Promise<string>;
  fail: (orderId: number, error: string) => Promise<unknown>;
  limit: number;
  sendTimeoutMs: number;
};

export type SubmitReport = { claimed: number; submitted: number; retrying: number; refused: number; results: string[]; error?: string };

const KEY = /^MER-ORDER-[0-9]{1,18}$/;
const REF = /^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$/;

export class DistributorError extends Error {
  constructor(what: string) { super(what); this.name = 'DistributorError'; }
}

function safeError(err: unknown): string {
  if (err instanceof DistributorError) return `DistributorError: ${err.message}`.slice(0, 200);
  return err instanceof Error && /^[A-Za-z]{1,40}$/.test(err.name) ? err.name : 'unknown';
}

// Results from submit_order that mean "done, do not send again".
const DONE = new Set(['submitted', 'already_submitted']);

export async function submitOrders(d: SubmitDeps): Promise<SubmitReport> {
  const report: SubmitReport = { claimed: 0, submitted: 0, retrying: 0, refused: 0, results: [] };
  let rows: ClaimedSubmission[];
  try {
    rows = await d.claim(d.limit);
    if (!Array.isArray(rows)) throw new Error('claim returned no rows');
  } catch (err) {
    return { ...report, error: `claim failed (${safeError(err)})` };
  }
  report.claimed = rows.length;
  for (const row of rows) {
    const orderId = Number(row.order_id);
    const key = row.idempotency_key;
    if (!Number.isSafeInteger(orderId) || orderId <= 0 || typeof key !== 'string' || !KEY.test(key)) {
      report.refused++; report.results.push(`${String(row.order_id)}: malformed claim`);
      continue;
    }
    // 1. Send. Anything that goes wrong here is retried later with the SAME key,
    //    so a distributor that did receive it answers with the same reference.
    let ref: string;
    try {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new DistributorError('timeout')), d.sendTimeoutMs); });
      try {
        const r = await Promise.race([d.send(row.payload, key), timeout]);
        ref = r?.distributor_ref;
      } finally {
        clearTimeout(timer);
      }
      if (typeof ref !== 'string' || !REF.test(ref)) throw new DistributorError('no valid distributor_ref in the response');
    } catch (err) {
      report.retrying++; report.results.push(`${orderId}: send failed, will retry`);
      try { await d.fail(orderId, safeError(err)); } catch { /* the lease expires and it is claimed again */ }
      continue;
    }
    // 2. Record. The database re-checks everything and is idempotent; a refusal
    //    here (conflict / blocked / not_confirmed) is final and is not retried.
    try {
      const result = await d.record(orderId, key, ref);
      if (DONE.has(result)) report.submitted++; else report.refused++;
      report.results.push(`${orderId}: ${result} ${ref}`);
    } catch (err) {
      // The distributor has it but we could not record it: retry. The resend
      // uses the same key, gets the same reference, and records it then.
      report.retrying++; report.results.push(`${orderId}: record failed, will retry`);
      try { await d.fail(orderId, `record: ${safeError(err)}`); } catch { /* lease expiry */ }
    }
  }
  return report;
}
