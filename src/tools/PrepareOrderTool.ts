import { env, User } from 'lua-cli';
import type { LuaTool } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { z } from 'zod';
import { runIntake, MSG_ERROR, type IntakeResult } from '../lib/intake.ts';
import { senderContext } from '../lib/identity.ts';
import { intakeDb, type Query } from '../lib/meridianDb.ts';
import { readInvoked, readRequestChannel } from '../lib/luaRequest.ts';

// The only way the model can start an order. It supplies what the rep SAID:
// chemist and product words, whole-pack quantities, or ids it was offered in an
// earlier clarification. It cannot supply a rep, a price, a total, a scheme, a
// credit decision or a code: the schema has no field for any of them.
// Who the rep is comes from the platform profile and Lua.request, never from
// the arguments. Uses AGENT_DATABASE_URL only.
const DB_TIMEOUT_MS = 20_000;

export default class PrepareOrderTool implements LuaTool {
  name = 'prepare_order';
  description =
    'Prepare a rep\'s order for a chemist and get the final order summary with its confirmation code. '
    + 'Pass the chemist and products exactly as the rep wrote them (or an id from options offered earlier) and whole-pack quantities. '
    + 'Never pass prices or totals. If the result asks for clarification, ask the rep; do not guess.';
  inputSchema = z.object({
    chemist_text: z.string().max(200).optional().describe('Chemist name as the rep wrote it, e.g. "Singh Medical Agency" or "sharma ji"'),
    chemist_id: z.number().int().positive().optional().describe('Only an id from options returned by an earlier prepare_order call. Keep chemist_text as the rep first wrote it.'),
    lines: z.array(z.object({
      product_text: z.string().max(200).optional().describe('Product as the rep wrote it, e.g. "Cetimer" or "ORS lemon"'),
      product_id: z.number().int().positive().optional().describe('Only an id from options returned by an earlier prepare_order call. Keep product_text as the rep first wrote it.'),
      quantity: z.number().describe('Number of packs (strips, bottles, boxes) as a whole number. If the rep\'s unit is unclear, ask first.'),
    })).min(1).max(100),
    source: z.enum(['text', 'voice', 'photo', 'excel', 'pdf']).optional()
      .describe('Only when the message says [ORDER READ FROM A ...]: the source it gives. Otherwise omit.'),
  });

  async execute(input: z.infer<typeof this.inputSchema>): Promise<IntakeResult> {
    try {
      const channel = readRequestChannel();
      const user = await User.get();
      const sender = senderContext({ channel, requestChannel: channel, invoked: readInvoked(), profile: user?._luaProfile });
      const url = env('AGENT_DATABASE_URL');
      if (!url) return { status: 'error', message: MSG_ERROR };
      const sql = neon(url);
      const q: Query = async (text, params) => await sql.query(text, params) as Record<string, unknown>[];
      let timer: ReturnType<typeof setTimeout> | undefined;
      const timeout = new Promise<IntakeResult>((resolve) => {
        timer = setTimeout(() => resolve({ status: 'error', message: MSG_ERROR }), DB_TIMEOUT_MS);
      });
      try {
        const sourceRef = `lua:${channel}:${Date.now()}`;
        return await Promise.race([runIntake(input, sender, intakeDb(q), sourceRef), timeout]);
      } finally {
        clearTimeout(timer);
      }
    } catch {
      return { status: 'error', message: MSG_ERROR };
    }
  }
}
