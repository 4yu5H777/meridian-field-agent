# Meridian Healthcare field agent (Lua, Assignment B)

A WhatsApp and email agent for Meridian's field reps, area managers and regional head. It runs on Lua, with PostgreSQL (Neon, schema `meridian`) as the system of record and a small mock distributor.

> **Deployment values** are filled in at release (phase 11) and marked `‹…›` below.

## Try it (no clone needed)

1. **Register yourself** as the demo rep, manager or regional head. This is one command; use your own number (with country code) and/or email:
   ```bash
   curl -X POST https://webhook.heylua.ai/baseAgent_0e951a65-33e3-45a8-a93c-61eb8c2641f3/reviewer-registration \
     -H 'Content-Type: application/json' -H 'x-registration-key: ‹KEY›' \
     -d '{"role":"rep","phone":"+91 98xxxxxxxx","email":"you@example.com"}'
   ```
   The roles map to three demo people who fit together:

   | `role` | You become | So you can |
   |---|---|---|
   | `rep` | Deepak Chauhan (REP-NOI-01) | Place orders for his chemists: Singh Medical Agency, Arogya Pharmacy and Om Sai Medicos. |
   | `manager` | Kavita Srivastava (ASM-NOI), Deepak's manager | Receive credit-approval emails and approve or reject them by reply, get the 7 PM summary, and ask about your team. |
   | `regional_head` | Anjali Mehra (RH-NORTH) | Ask about all teams. |

   To move a contact to another role, register it again with the new role. To take it off, send `{"remove": true, "phone": "..."}`. A number or email that belongs to anyone else in the data is refused, never taken over. Anything you have not registered gets only *"Sorry, this assistant is only for registered Meridian Healthcare staff…"*.
2. **Talk to it.** On WhatsApp, first open https://wa.me/13023778932?text=link-me-to:baseAgent_0e951a65-33e3-45a8-a93c-61eb8c2641f3 and send the prefilled message (this links you to the agent on Lua's test number) or email `‹AGENT_EMAIL›`. Send an order in English, Hindi or a mix: typed, as a voice note, a photo of an order-book page, an Excel/CSV sheet or a PDF (see [`samples/`](samples/)). Confirm by typing the `YES <code>` line from the summary.
3. **Trigger a distributor callback**, including a repeated one:
   ```bash
   MOCK_DISTRIBUTOR_URL=https://webhook.heylua.ai/baseAgent_agent_1790702057434_m2q98ujj2 DISTRIBUTOR_API_KEY=‹KEY› node mock-distributor/trigger.mjs ‹REF› DISPATCHED --event-id EVT-demo-1
   MOCK_DISTRIBUTOR_URL=https://webhook.heylua.ai/baseAgent_agent_1790702057434_m2q98ujj2 DISTRIBUTOR_API_KEY=‹KEY› node mock-distributor/trigger.mjs --replay EVT-demo-1   # the same event again
   ```
   You can also POST to `https://webhook.heylua.ai/baseAgent_agent_1790702057434_m2q98ujj2/admin` with `{"action":"callback","distributor_ref","status","event_id"}`, `{"action":"replay","event_id"}` or `{"action":"list"}`, using header `Authorization: Bearer ‹KEY›`. `trigger.mjs --list` shows the orders and their refs (`‹REF›`, e.g. `MD-000001`).
4. **Check the numbers yourself** with the read-only database login: `‹READONLY_DATABASE_URL›`. It can read every table and cannot write anything.

## Where things live

| Rule / capability | Enforced in | Why there |
|---|---|---|
| Identity: unknown senders get nothing | Preprocessor `identity-gate` (runs first) + `screen_sender()`. Every tool and function also resolves the sender itself. | Before the model sees anything. |
| Confirmation: nothing leaves without a typed YES | Preprocessor `confirmation-gate` → `confirm_order_by_code()` (system role only). The `orders_guard` trigger refuses any status change without a used confirmation matching the frozen total and lines. | The model has no confirm tool, and the database refuses anything else. |
| Credit: approval covers one order | Trigger → outbox email to the manager. Preprocessor `credit-reply-gate` → `decide_credit_by_reply()` (the replier must be the manager on record). `orders_guard` rechecks the limit. | Deterministic, and outside the model. |
| Price, schemes, totals, credit headroom | `prepare_order()` / `order_lines_price()` in SQL. Postprocessor `summary-integrity` replaces any summary with the canonical one. | Money is never the model's arithmetic. |
| Manager answers | Tool `team_report` → `meridian_report()` (fixed reports, scoped with `visible_rep_ids`). Postprocessor `report-integrity` replaces a reply containing any number the report does not contain. | Exact figures; no SQL from the model. |
| Voice / photo / PDF / Excel | Preprocessor `media-normalizer`: Lua `AI.generate` (Gemini) for voice, photo and PDF; a deterministic parser for Excel/CSV. Everything is validated, then becomes the same `prepare_order` input as a typed order. | Unsure input gets a question, never a guess. |
| Hindi / Hinglish names, the rep's own spellings | `src/lib/lang.ts` (spelling variants, transliteration), `match_*()` (pg_trgm), aliases learned only when the rep confirms (schema section 18). | Matching thresholds unchanged. |
| Distributor | Job `distributor-submitter` (idempotent `submit_order`). Webhook `distributor-callback` (HMAC over canonical JSON; duplicate, out-of-order and unknown-status safe). | Repeat-safe. |
| 7 PM summary | Job `evening-summary` → `enqueue_evening_summaries()` → notification outbox. | Once per manager per day. |

Database roles: `meridian_agent` (model-facing tools; reads only chemists, route_stops and products), `meridian_system` (gates, jobs, webhooks) and `meridian_readonly` (the panel). None of them can write to a table directly; every write goes through a SECURITY DEFINER function.

## Layout

- `db/`: `schema.sql` (sections 1–19), `seed.sql`, `privileges.sql`, and `checks-*.sql` (DB test suites, run in BEGIN … ROLLBACK).
- `src/`: `index.ts` (the agent), `tools/`, `preprocessors/`, `postprocessors/`, `jobs/`, `webhooks/`, `lib/` (pure logic, unit-tested).
- `tests/`: unit tests (`node --test`) and `intake.integration.test.ts` (real database, rolled back).
- `mock-distributor/`: the distributor service and the callback trigger.
- `samples/`: the test inputs and what each should produce.
- `docs/CHECKLIST.md`: the assignment checklist and the red-team results.

## Running the checks (local)

Needs `.env.owner` (owner and read-only URLs) and `.env` (agent and system URLs). Neither is committed.

```bash
npm run db:reset          # rebuild schema + seed + grants
npm run db:check:all      # every DB suite
npm run test:unit
npm run test:integration  # real database, rolled back
npm run register -- --role rep --phone "+91 98xxxxxxxx"   # local registration
```
