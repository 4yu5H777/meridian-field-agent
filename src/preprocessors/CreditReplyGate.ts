import { PreProcessor, Lua, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { handleCreditReply, findTokens, REPLY_ERROR } from '../lib/creditReply.ts';
import type { GateMessage } from '../lib/confirmation.ts';
import { systemDb, type Query } from '../lib/meridianDb.ts';
import { readInvoked, readRequestChannel } from '../lib/luaRequest.ts';
import { runDispatcher } from '../lib/dispatch.ts';

// Rule "Credit": a manager approves or rejects by replying to the approval email.
//
// Runs before the model (priority 3, after the confirmation gate). Any turn
// carrying a CR- approval reference is handled here and ALWAYS blocked: the
// model never sees an approval reply and has no way to decide credit. The
// replier's identity is the platform's (user._luaProfile emails), never the
// email text; meridian.decide_credit_by_reply checks they are the manager on
// record and applies the decision to that one order. SYSTEM_DATABASE_URL only.
const DB_TIMEOUT_MS = 15_000;

// The inbound email's subject, from the channel's raw event (both email modes
// carry `subject`). Anything unreadable is treated as no subject.
function readSubject(): string | undefined {
  try {
    const payload = (Lua as unknown as { request?: { webhook?: { payload?: unknown } } })?.request?.webhook?.payload;
    const subject = (payload as { subject?: unknown } | undefined)?.subject;
    return typeof subject === 'string' ? subject.slice(0, 500) : undefined;
  } catch {
    return undefined;
  }
}

export default new PreProcessor({
  name: 'credit-reply-gate',
  description: 'Records a manager\'s APPROVE / REJECT reply to a credit approval email; blocks it from the model.',
  priority: 3,
  async execute(user, messages, channel) {
    try {
      const url = env('SYSTEM_DATABASE_URL');
      const q: Query = async (text, params) => {
        if (!url) throw new Error('SYSTEM_DATABASE_URL is not set');
        return await neon(url).query(text, params) as Record<string, unknown>[];
      };
      const db = systemDb(q);
      const outcome = await handleCreditReply({
        messages: messages as GateMessage[], subject: readSubject(), channel, requestChannel: readRequestChannel(),
        invoked: readInvoked(), profile: user?._luaProfile, decide: db.decideByReply, timeoutMs: DB_TIMEOUT_MS,
      });
      if (outcome.action === 'proceed') return { action: 'proceed' };
      console.info(`credit-reply-gate: ${outcome.log}`);
      if (outcome.decided) {
        // Tell the rep now rather than at the next dispatcher run.
        const report = await runDispatcher(10);
        console.info(`credit-reply-gate: dispatched ${report.sent}/${report.claimed}`);
      }
      return { action: 'block', response: outcome.response };
    } catch {
      // Fail closed: anything carrying an approval reference never reaches the model.
      let hasToken = true;
      try {
        hasToken = (messages as GateMessage[]).some((m) => m.type === 'text' && findTokens(m.text).length > 0)
          || findTokens(readSubject() ?? '').length > 0;
      } catch { /* keep hasToken = true */ }
      console.error('credit-reply-gate: unexpected failure');
      return hasToken ? { action: 'block', response: REPLY_ERROR } : { action: 'proceed' };
    }
  },
});
