import { PreProcessor, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { screenTurn, REPLY_UNAVAILABLE } from '../lib/identityGate.ts';
import { systemDb } from '../lib/meridianDb.ts';
import { readInvoked, readRequestChannel } from '../lib/luaRequest.ts';

// Rule "Identity": the first thing that runs on every inbound message
// (priority 1, before the confirmation and credit-reply gates; the server refused
// priority 0 on push). Unknown,
// retired, deactivated or ambiguous senders are blocked here with a fixed
// reply and never reach the model or any tool. See src/lib/identityGate.ts.
// Identity comes only from user._luaProfile; meridian.screen_sender decides.
// SYSTEM_DATABASE_URL only.
const DB_TIMEOUT_MS = 15_000;

function luaUserIdOf(user: unknown): string | undefined {
  const id = (user as { _luaProfile?: { userId?: unknown } } | null)?._luaProfile?.userId;
  return typeof id === 'string' && /^[A-Za-z0-9_:.-]{1,128}$/.test(id) ? id : undefined;
}

export default new PreProcessor({
  name: 'identity-gate',
  description: 'Blocks anyone who is not a registered Meridian rep, manager or regional head before the model sees the message.',
  priority: 1,
  async execute(user, _messages, channel) {
    try {
      const url = env('SYSTEM_DATABASE_URL');
      const db = systemDb(async (text, params) => {
        if (!url) throw new Error('SYSTEM_DATABASE_URL is not set');
        return await neon(url).query(text, params) as Record<string, unknown>[];
      });
      const outcome = await screenTurn({
        channel, requestChannel: readRequestChannel(), invoked: readInvoked(), profile: user?._luaProfile,
        // The platform's own id for this person, so the dispatcher can reach them
        // back on WhatsApp via user.send() (Lua's shared test number).
        screen: (ch, contacts) => db.screenSender(ch, contacts, luaUserIdOf(user)), timeoutMs: DB_TIMEOUT_MS,
      });
      console.info(`identity-gate: ${outcome.log} (channel ${channel})`);
      return outcome.action === 'proceed' ? { action: 'proceed' } : { action: 'block', response: outcome.response };
    } catch {
      // Never throw: the platform would skip this gate and let the turn through.
      console.error('identity-gate: unexpected failure');
      return { action: 'block', response: REPLY_UNAVAILABLE };
    }
  },
});
