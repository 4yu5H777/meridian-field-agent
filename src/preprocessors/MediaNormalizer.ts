import { PreProcessor, AI, env } from 'lua-cli';
import { normalizeTurn, replyReadFailed } from '../lib/media/normalize.ts';
import { httpsFetcher } from '../lib/media/load.ts';
import { DEFAULT_MEDIA_MODEL, type AiCall } from '../lib/media/reader.ts';

// Voice notes, photos of order books, Excel/CSV and PDF orders become the same
// canonical order text a typed order produces (src/lib/media/). Runs AFTER the
// identity (1), confirmation (2) and credit-reply (3) gates, so none of them is
// bypassed: an unknown sender never gets here, and a confirmation is only ever
// a typed text part, which the confirmation gate has already handled. Turns
// without media pass through untouched.
//
// Readers run on Lua (AI.generate); no database access and no credentials here.
const AI_TIMEOUT_MS = 60_000;
const FETCH_TIMEOUT_MS = 20_000;

const aiCall: AiCall = async (input) =>
  await AI.generate(input as unknown as Parameters<typeof AI.generate>[0] & object) as { output?: unknown; finishReason?: string };

export default new PreProcessor({
  name: 'media-normalizer',
  description: 'Turns voice notes, order-book photos, Excel/CSV and PDF orders into a checked canonical order, or asks the rep to clarify.',
  priority: 10,
  async execute(_user, messages) {
    let hasMedia = true;
    try {
      hasMedia = (messages as { type?: string }[]).some((m) => m?.type === 'image' || m?.type === 'file');
      if (!hasMedia) return { action: 'proceed' };
      const outcome = await normalizeTurn({
        messages, ai: aiCall, model: env('MEDIA_MODEL') || DEFAULT_MEDIA_MODEL,
        fetchBytes: httpsFetcher(FETCH_TIMEOUT_MS), aiTimeoutMs: AI_TIMEOUT_MS,
      });
      console.info(`media-normalizer: ${outcome.log}`);
      if (outcome.action === 'block') return { action: 'block', response: outcome.response };
      return outcome.modifiedMessage ? { action: 'proceed', modifiedMessage: outcome.modifiedMessage } : { action: 'proceed' };
    } catch {
      // Never throw (the platform would skip this and hand raw media to the model).
      console.error('media-normalizer: unexpected failure');
      return hasMedia ? { action: 'block', response: replyReadFailed('file') } : { action: 'proceed' };
    }
  },
});
