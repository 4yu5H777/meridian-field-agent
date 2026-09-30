import { LuaWebhook, env } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { handleRegistration } from '../lib/registration.ts';

// POST https://webhook.heylua.ai/<agentId>/reviewer-registration
// Puts a reviewer's own WhatsApp number / email on the demo rep, manager or
// regional head (see src/lib/registration.ts and schema section 19).
// Key in code, not a platform `secret` literal: REGISTRATION_KEY from the
// environment (at least 24 characters, else every call is refused).
// SYSTEM_DATABASE_URL; the model is never involved.
export default new LuaWebhook({
  name: 'reviewer-registration',
  description: 'Registers a reviewer\'s own WhatsApp number or email as the demo rep, manager or regional head (key-protected).',
  async execute(event) {
    const dbUrl = env('SYSTEM_DATABASE_URL');
    const res = await handleRegistration({
      headers: event?.headers, body: event?.body, key: env('REGISTRATION_KEY'), timeoutMs: 15_000,
      register: async (role, channel, value, remove) => {
        if (!dbUrl) throw new Error('SYSTEM_DATABASE_URL is not set');
        const [r] = await neon(dbUrl).query('SELECT meridian.register_demo_contact($1, $2, $3, $4) AS r', [role, channel, value, remove]) as { r: unknown }[];
        return r?.r;
      },
    });
    console.info(`reviewer-registration: ${'results' in res ? res.results.map((r) => `${r.channel}:${r.ok ? r.status : r.error}`).join(',') : res.error}`);
    return res;
  },
});
