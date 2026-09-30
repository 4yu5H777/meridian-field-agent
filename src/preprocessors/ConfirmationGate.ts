import { PreProcessor, Lua, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import {
  handleTurn, confirmationCandidate, parseConfirmationText, REPLY_ERROR,
  type GateMessage, type InvokedState, type DbConfirmResult,
} from '../lib/confirmation';

// Rule "Confirmation": the only way an order gets a rep's yes.
//
// Runs on every inbound message right after the identity gate (priority 2), before the model and
// before any preprocessor that could turn a voice note into text. When the
// turn is exactly one typed "YES 4821" (see src/lib/confirmation.ts), it is
// answered here and ALWAYS blocked: the model never sees a confirmation
// attempt, so it can neither perform one nor claim one happened. Every other
// turn proceeds untouched; this gate adds nothing to the model's messages or
// metadata.
//
// Identity comes only from the platform's read-only user._luaProfile. The
// database (meridian.confirm_order_by_code, meridian_system role) resolves the
// rep from those contacts and checks the code, expiry, reuse and that the
// order is exactly the summary that was shown.
//
// SYSTEM_DATABASE_URL is read here and nowhere else. No tool may read it:
// tools use AGENT_DATABASE_URL, which cannot execute confirm_order_by_code.

const DB_TIMEOUT_MS = 15_000;

// Was this turn started by code (Agents.invoke) rather than typed by a person?
// Anything we cannot read counts as 'unknown', which never confirms.
function invokedState(): InvokedState {
  try {
    // invokedBy is newer than the lua-cli 3.39.4 types, so read it untyped.
    const request = (Lua as unknown as { request?: Record<string, unknown> } | undefined)?.request;
    if (!request) return 'unknown';
    return request.invokedBy === undefined || request.invokedBy === null ? 'no' : 'yes';
  } catch {
    return 'unknown';
  }
}

function requestChannel(): string | undefined {
  try {
    const channel = (Lua as { request?: { channel?: unknown } } | undefined)?.request?.channel;
    return typeof channel === 'string' ? channel : undefined;
  } catch {
    return undefined;
  }
}

async function confirmInDatabase(channel: string, contacts: string[], code: string): Promise<DbConfirmResult | null> {
  const url = env('SYSTEM_DATABASE_URL');
  if (!url) throw new Error('SYSTEM_DATABASE_URL is not set');
  const sql = neon(url);
  const rows = await sql.query('SELECT * FROM meridian.confirm_order_by_code($1, $2::text[], $3)', [channel, contacts, code]);
  return Array.isArray(rows) && rows.length === 1 ? (rows[0] as DbConfirmResult) : null;
}

export default new PreProcessor({
  name: 'confirmation-gate',
  description: 'Handles a rep typing "YES <code>" to confirm an order summary; blocks it from the model.',
  priority: 2,
  async execute(user, messages, channel) {
    try {
      const outcome = await handleTurn({
        messages: messages as GateMessage[],
        channel,
        requestChannel: requestChannel(),
        invoked: invokedState(),
        profile: user?._luaProfile,
        confirm: confirmInDatabase,
        timeoutMs: DB_TIMEOUT_MS,
      });
      if (outcome.action === 'proceed') return { action: 'proceed' };
      console.info(`confirmation-gate: ${outcome.log} (channel ${channel})`);
      return { action: 'block', response: outcome.response };
    } catch {
      // Should not happen (handleTurn catches database failures itself). Fail
      // closed: proceed only if this turn is certainly not a confirmation.
      let attempt = true;
      try {
        const candidate = confirmationCandidate(messages as GateMessage[], channel);
        attempt = candidate !== null && parseConfirmationText(candidate) !== null;
      } catch { /* keep attempt = true */ }
      console.error('confirmation-gate: unexpected failure');
      return attempt ? { action: 'block', response: REPLY_ERROR } : { action: 'proceed' };
    }
  },
});
