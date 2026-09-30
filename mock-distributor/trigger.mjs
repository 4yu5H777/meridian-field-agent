// Trigger a distributor callback by hand (demo and testing), against the
// deployed mock distributor (a separate Lua agent, meridian-mock-distributor).
//   MOCK_DISTRIBUTOR_URL=https://webhook.heylua.ai/<mock agent id> DISTRIBUTOR_API_KEY=... node mock-distributor/trigger.mjs MD-000081 DISPATCHED
//   ... trigger.mjs MD-000081 ACCEPTED --event-id EVT-demo-1     (choose the event id)
//   ... trigger.mjs --replay EVT-demo-1                          (send the SAME event again: a duplicate)
//   ... trigger.mjs MD-999999 DISPATCHED                          (an order the agent never sent)
//   ... trigger.mjs MD-000081 ON_HOLD                              (a status nobody told the agent about)
//   ... trigger.mjs --list
// The same calls as curl: POST <MOCK_DISTRIBUTOR_URL>/admin with
//   Authorization: Bearer <key>  and  {"action":"callback"|"replay"|"list", ...}
const base = (process.env.MOCK_DISTRIBUTOR_URL ?? '').replace(/\/+$/, '');
const key = process.env.DISTRIBUTOR_API_KEY;
if (!base || !key) { console.error('Set MOCK_DISTRIBUTOR_URL and DISTRIBUTOR_API_KEY.'); process.exit(1); }

const args = process.argv.slice(2);
const opt = (n) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : undefined; };
let body;
if (args[0] === '--list') body = { action: 'list' };
else if (args[0] === '--replay') body = { action: 'replay', event_id: args[1] };
else if (args[0] && args[1]) body = { action: 'callback', distributor_ref: args[0], status: args[1], event_id: opt('--event-id'), reason: opt('--reason') };
else { console.error('usage: trigger.mjs <distributor_ref> <STATUS> [--event-id ID] [--reason TEXT] | --replay <event_id> | --list'); process.exit(1); }

const res = await fetch(`${base}/admin`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` }, body: JSON.stringify(body) });
console.log(JSON.stringify(await res.json().catch(() => ({ http_status: res.status })), null, 2));
