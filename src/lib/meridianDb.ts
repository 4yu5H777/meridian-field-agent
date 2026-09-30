// The SQL behind IntakeDb and IntegrityDb, over any "run a parameterised
// query, get rows" function. The Lua code passes the Neon HTTP driver; the
// integration tests pass a pg client inside BEGIN ... ROLLBACK. Only functions
// and tables granted to meridian_agent are used. Pure (no driver imports).
import type { Candidate, IntakeDb } from './intake.ts';
import type { IntegrityDb, LiveSummaryRow } from './summary.ts';
import type { ClaimedNotification } from './notify.ts';
import type { ClaimedSubmission } from './submit.ts';
import type { CallbackEvent } from './callback.ts';

export type Query = (sql: string, params: unknown[]) => Promise<Record<string, unknown>[]>;

const num = (v: unknown) => Number(v);        // bigint columns arrive as strings

export function intakeDb(q: Query): IntakeDb {
  return {
    async identify(channel, contacts) {
      const [r] = await q('SELECT result, user_id, role FROM meridian.identify_sender($1, $2::text[])', [channel, contacts]);
      return { result: String(r?.result ?? ''), user_id: r?.user_id == null ? null : num(r.user_id), role: r?.role == null ? null : String(r.role) };
    },
    async matchChemist(repId, text) {
      const rows = await q(
        `SELECT m.chemist_id AS id, m.chemist_name AS name, c.locality AS detail, m.score, m.is_rep_alias
           FROM meridian.match_chemist($1, $2) m JOIN meridian.chemists c ON c.id = m.chemist_id`, [repId, text]);
      return rows.map((r): Candidate => ({ id: num(r.id), name: String(r.name), detail: String(r.detail), score: Number(r.score), isRepAlias: r.is_rep_alias === true }));
    },
    async matchProduct(repId, text) {
      const rows = await q(
        `SELECT m.product_id AS id, m.product_name AS name, p.pack AS detail, m.score, m.is_rep_alias
           FROM meridian.match_product($1, $2) m JOIN meridian.products p ON p.id = m.product_id`, [repId, text]);
      return rows.map((r): Candidate => ({ id: num(r.id), name: String(r.name), detail: String(r.detail), score: Number(r.score), isRepAlias: r.is_rep_alias === true }));
    },
    async repChemist(repId, chemistId) {
      const [r] = await q(
        `SELECT c.id, c.name, c.locality AS detail FROM meridian.chemists c
          WHERE c.id = $2 AND EXISTS (SELECT 1 FROM meridian.route_stops rs WHERE rs.rep_id = $1 AND rs.chemist_id = c.id)`,
        [repId, chemistId]);
      return r ? { id: num(r.id), name: String(r.name), detail: String(r.detail) } : null;
    },
    async activeProduct(productId) {
      const [r] = await q('SELECT id, name, pack AS detail FROM meridian.products WHERE id = $1 AND is_active', [productId]);
      return r ? { id: num(r.id), name: String(r.name), detail: String(r.detail) } : null;
    },
    async prepareOrder(channel, contacts, chemistId, lines, sourceRef, inputType = 'text', chemistText = '') {
      const [r] = await q('SELECT meridian.prepare_order($1, $2::text[], $3, $4::jsonb, $5, $6, $7) AS result',
        [channel, contacts, chemistId, JSON.stringify(lines), inputType, sourceRef, chemistText || null]);
      return r?.result;
    },
  };
}

export function integrityDb(q: Query): IntegrityDb {
  return {
    async liveSummaries(channel, contacts) {
      return await q('SELECT confirmation_id, order_id, code, delivered, summary FROM meridian.live_order_summaries($1, $2::text[])',
        [channel, contacts]) as LiveSummaryRow[];
    },
    async markDelivered(channel, contacts, ids) {
      const [r] = await q('SELECT meridian.mark_summaries_delivered($1, $2::text[], $3::bigint[]) AS n', [channel, contacts, ids]);
      return num(r?.n ?? 0);
    },
  };
}

// System-role calls (SYSTEM_DATABASE_URL): the notification dispatcher and the
// credit-reply and identity gates. Never used by a model-facing tool.
export type SystemDb = {
  claim: (limit: number) => Promise<ClaimedNotification[]>;
  complete: (id: number, providerRef: string) => Promise<boolean>;
  fail: (id: number, error: string) => Promise<string>;
  decideByReply: (contacts: string[], token: string, decision: 'approved' | 'rejected', note: string) => Promise<string>;
  claimSubmissions: (limit: number) => Promise<ClaimedSubmission[]>;
  submitOrder: (orderId: number, idempotencyKey: string, distributorRef: string) => Promise<string>;
  failSubmission: (orderId: number, error: string) => Promise<string>;
  recordDistributorEvent: (e: CallbackEvent) => Promise<string>;
  screenSender: (channel: string, contacts: string[], luaUserId?: string) => Promise<{ result?: unknown; role?: unknown } | null>;
};

export function systemDb(q: Query): SystemDb {
  return {
    async claim(limit) {
      return await q('SELECT id, kind, channel, address, payload, attempts, lua_user_id FROM meridian.claim_notifications($1, $2)', [limit, 120]) as ClaimedNotification[];
    },
    async complete(id, providerRef) {
      const [r] = await q('SELECT meridian.complete_notification($1, $2) AS ok', [id, providerRef]);
      return r?.ok === true;
    },
    async fail(id, error) {
      const [r] = await q('SELECT meridian.fail_notification($1, $2) AS status', [id, error]);
      return String(r?.status ?? '');
    },
    async decideByReply(contacts, token, decision, note) {
      const [r] = await q('SELECT meridian.decide_credit_by_reply($1::text[], $2, $3, $4) AS result', [contacts, token, decision, note]);
      return String(r?.result ?? '');
    },
    async claimSubmissions(limit) {
      return await q('SELECT order_id, idempotency_key, attempts, payload FROM meridian.claim_submissions($1, $2)', [limit, 120]) as ClaimedSubmission[];
    },
    async submitOrder(orderId, idempotencyKey, distributorRef) {
      const [r] = await q('SELECT meridian.submit_order($1, $2, $3) AS result', [orderId, idempotencyKey, distributorRef]);
      return String(r?.result ?? '');
    },
    async recordDistributorEvent(e) {
      const [r] = await q('SELECT meridian.record_distributor_event($1, $2, $3, $4::timestamptz, $5::jsonb) AS result',
        [e.event_id, e.distributor_ref, e.status, e.occurred_at, JSON.stringify(e.payload)]);
      return String(r?.result ?? '');
    },
    async screenSender(channel, contacts, luaUserId) {
      const [r] = await q('SELECT meridian.screen_sender($1, $2::text[], $3) AS r', [channel, contacts, luaUserId ?? null]);
      return (r?.r ?? null) as { result?: unknown; role?: unknown } | null;
    },
    async failSubmission(orderId, error) {
      const [r] = await q('SELECT meridian.fail_submission($1, $2) AS status', [orderId, error]);
      return String(r?.status ?? '');
    },
  };
}
