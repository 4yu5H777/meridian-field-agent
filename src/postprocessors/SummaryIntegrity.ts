import { PostProcessor, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { enforceSummaryIntegrity, mightCarryOrderData, SUMMARY_UNAVAILABLE } from '../lib/summary.ts';
import { senderContext } from '../lib/identity.ts';
import { integrityDb, type Query } from '../lib/meridianDb.ts';
import { readInvoked, readRequestChannel } from '../lib/luaRequest.ts';

// The rep only ever sees the canonical order summary.
//
// Runs on every reply before it is sent (priority 1: first in the chain). If
// the rep has a summary that has not been shown yet, the whole reply becomes
// that summary; if the reply mentions one of the rep's live codes, it becomes
// that order's summary; a confirm instruction with a code that is not live is
// withheld. The summary is rendered from meridian.order_summary(), so the model
// cannot alter products, quantities, prices, discounts, free units, schemes,
// the total, the warnings, the code or the expiry.
//
// The platform skips a postprocessor that throws, and treats an empty reply as
// "no change", so this never throws and never returns ''. When the live
// summaries cannot be read, a reply that might carry order data is replaced by
// a fixed message. Uses AGENT_DATABASE_URL only.
const DB_TIMEOUT_MS = 15_000;

export default new PostProcessor({
  name: 'summary-integrity',
  description: 'Replaces any order summary in a reply with the canonical one from the database.',
  priority: 1,
  async execute(user, _message, response, channel) {
    try {
      const sender = senderContext({ channel, requestChannel: readRequestChannel(), invoked: readInvoked(), profile: user?._luaProfile });
      const url = env('AGENT_DATABASE_URL');
      const q: Query = async (text, params) => {
        if (!url) throw new Error('AGENT_DATABASE_URL is not set');
        return await neon(url).query(text, params) as Record<string, unknown>[];
      };
      const outcome = await enforceSummaryIntegrity({ response, sender, db: integrityDb(q), timeoutMs: DB_TIMEOUT_MS });
      console.info(`summary-integrity: ${outcome.log}`);
      return { modifiedResponse: outcome.text || SUMMARY_UNAVAILABLE };
    } catch {
      console.error('summary-integrity: unexpected failure');
      const text = typeof response === 'string' ? response : '';
      return { modifiedResponse: text && !mightCarryOrderData(text) ? text : SUMMARY_UNAVAILABLE };
    }
  },
});
