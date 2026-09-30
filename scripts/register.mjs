// Register (or remove) a WhatsApp number / email as the demo rep, manager or
// regional head, from this machine. Same database function as the
// reviewer-registration webhook, as meridian_system.
//
//   npm run register -- --role rep --phone "+91 98xxxxxxxx" --email you@example.com
//   npm run register -- --role manager --email boss@example.com
//   npm run register -- --remove --phone "+91 98xxxxxxxx"
//
// SYSTEM_DATABASE_URL from .env; never printed.
import pg from 'pg';

const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(`--${name}`); return i >= 0 ? args[i + 1] : undefined; };
const remove = args.includes('--remove');
const role = remove ? null : opt('role');
const contacts = [['whatsapp', opt('phone')], ['email', opt('email')]].filter(([, v]) => v);
if ((!remove && !['rep', 'manager', 'regional_head'].includes(role)) || contacts.length === 0) {
  console.error('usage: npm run register -- --role rep|manager|regional_head [--phone "+91 ..."] [--email you@example.com]\n       npm run register -- --remove [--phone ...] [--email ...]');
  process.exit(1);
}
const url = process.env.SYSTEM_DATABASE_URL;
if (!url) { console.error('SYSTEM_DATABASE_URL is not set (run with: node --env-file=.env scripts/register.mjs ...)'); process.exit(1); }

const client = new pg.Client({ connectionString: url.replace(/sslmode=(require|prefer|verify-ca)/, 'sslmode=verify-full') });
let failed = false;
try {
  await client.connect();
  for (const [channel, value] of contacts) {
    const { rows: [{ r }] } = await client.query('SELECT meridian.register_demo_contact($1, $2, $3, $4) AS r', [role, channel, value, remove]);
    console.log(`${channel}: ${r.ok ? `${r.status}${r.as ? ` as ${r.as} (${role})` : ''}` : `refused (${r.error})`}`);
    failed ||= !r.ok;
  }
} catch (err) {
  console.error(`failed: ${String(err?.message ?? err).split(url).join('[SYSTEM_DATABASE_URL]').replace(/postgres(ql)?:\/\/\S+/gi, '[connection string]')}`);
  failed = true;
} finally {
  await client.end().catch(() => {});
}
process.exit(failed ? 1 : 0);
