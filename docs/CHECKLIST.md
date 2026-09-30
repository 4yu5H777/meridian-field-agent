# Assignment B: checklist and red-team results

Status as of 2026-09-30, end of phase 10. Everything here is built and tested **locally and against the Neon database**. Nothing from phases 1–10 is deployed yet: production still runs agent version 1 (the connectivity spike only). Deployment is phase 11.

Legend: **Done** = built and tested · **Deploy** = built, goes live in phase 11 · **You** = needs the candidate (recording, write-up, video) · **Gap** = known limit, stated.

## 1. What we send (brief section 08)

| Item | Status | Evidence / what is left |
|---|---|---|
| Agent live on Lua's test WhatsApp number, with its agent ID | Deploy | Push, create and promote a new agent version; link the test number. |
| Agent email address, working both ways | Deploy | Email channel on the agent. Outbound approval, decision and 7 PM emails go through the outbox; inbound replies are handled by `credit-reply-gate`. |
| A documented way to register our own numbers and emails | Done → Deploy | One `curl` to the `reviewer-registration` webhook (README), or `npm run register` locally. `register_demo_contact()` puts contacts only on the demo rep, manager or regional head and never takes over anyone else's. Checks: identity 46, unit `registration.test.ts`. Needs `REGISTRATION_KEY` set at deploy. |
| Read-only database access, mock data loaded | Done → Deploy | Role `meridian_readonly` (checks: readonly 22). Share `READONLY_DATABASE_URL` at submission. |
| Mock distributor + a way to trigger a callback, including a repeated one | Done → Deploy | `mock-distributor/` (6 tests); `trigger.mjs` with `--replay`; `/admin/callback` and `/admin/replay`. Needs hosting plus `CALLBACK_URL` / `CALLBACK_SECRET`. |
| Sample inputs in a folder | Done / You | `samples/` with its README of expected outcomes. **Missing: a real Hindi voice note recorded on a phone.** |
| Repository with read access | Deploy | Not a git repository yet; `.gitignore` already excludes `.env*`, `node_modules` and `dist-v2`. |
| Write-up, two pages, the six headings | You | Not started. This checklist and the README hold most of the material. |
| Walkthrough video, 10 minutes | You | After deployment. |
| Architecture diagram, one page | You | Not started. The README's "Where things live" table is the content. |

## 2. The five capabilities (section 03)

| Capability | Status | Evidence |
|---|---|---|
| Take an order (all forms) → distributor after the rep's yes | Done → Deploy | `prepare_order` (intake 56); confirmation (confirmation 52); submission (submission 44); media (`media.test.ts`, integration "voice, photo, PDF and Excel … exactly the typed order"). |
| Credit approval by manager email reply; rep told on WhatsApp | Done → Deploy | credit 52; integration "credit approval by email reply, end to end". |
| Dispatch updates to the rep | Done → Deploy | callbacks 25; integration "distributor callbacks end to end (signed, idempotent, ordered)". |
| 7 PM evening summary to each manager | Done → Deploy | summary 25; integration "7 PM evening emails". |
| Answer a manager, exact numbers | Done → Deploy | reports 34; integration "team questions scoped" and "every manager answer is the database's figures"; postprocessor `report-integrity`. |

## 3. The business rules (section 04), and where each is enforced

| Rule | Enforced by (code, not the model) |
|---|---|
| Identity | `identity-gate` preprocessor (priority 1, first) → `screen_sender()`; every function resolves the sender from platform contacts, never from an id the model gives. |
| Who sees what | `visible_rep_ids()` inside `meridian_report()`, `evening_summary()` and `live_order_summaries()`. The agent credential cannot read orders at all (R1). |
| Price from the price list only | `order_lines_price()` trigger; `prepare_order` input has no price field (agent check "a price in the line is ignored"). |
| Schemes | Priced in SQL within their start/end dates; shown on the summary (intake checks). |
| Credit: one approval, one order | `orders_guard` rechecks owed + total against the limit, needing an approval for *this* order at *this* total (credit 52). |
| Confirmation | `confirm_order_by_code` (system role only) plus `orders_guard`: no status past `awaiting_confirmation` without a used confirmation matching the frozen total and lines (confirmation 52). |
| Duplicates (same rep, chemist, lines within 10 minutes) | `find_possible_duplicate()` inside `prepare_order`; the summary says so once (intake checks). |
| Off route: allowed and flagged | `is_off_route` set at creation; shown on the summary and in the 7 PM email (summary 25). |

## 4. "The parts that are actually hard" (section 05)

| Problem | Answer | Evidence |
|---|---|---|
| Who is this? | `identity-gate` first; unknown, retired, deactivated or ambiguous senders all get the same fixed refusal. | identity 46, `identity-gate.test.ts`, integration "identity gate". |
| Nothing leaves without a yes | The `orders_guard` trigger plus a system-only `confirm_order_by_code`; the model has no confirm tool; media can never confirm. | confirmation 52, agent 83, integration "media can never confirm them". |
| Money is never the model's arithmetic | SQL pricing, `summary-integrity`, `report-integrity`. | summary tests, `reportText.test.ts`. |
| Voice notes (Hindi, English, busy counter; model without audio) | `media-normalizer`: transcribe (Gemini on Lua), then extract; low confidence or an unclear quantity gets a question; every quantity must appear in the transcript. | `media.test.ts`; live smoke. **Gap: no real Hindi voice note tested yet.** |
| Paper and spreadsheets (angled photo; 60-line sheet, merged cells, bad total row; PDF PO) | Photo and PDF via reader + validation; Excel/CSV parsed deterministically; total rows ignored wherever they are labelled; up to 100 lines. | `media.test.ts` "the brief's sheet", integration "60-line Excel PO", `samples/`. |
| Names spelled many ways; remember what this rep meant | pg_trgm matching + Hindi/Hinglish spelling variants (`lang.ts`) + per-rep aliases learned on confirmation. | aliases 36, `lang.test.ts`, integration "Hindi, Hinglish and mixed-script" and "next time their own spelling just works". |
| Callbacks behave badly | HMAC over canonical JSON; idempotent on event id; out of order and unknown status are stored without effect. | callbacks 25. |
| Email replies behave badly | Token-bound; "ok" three hours later still decides only that order at its frozen total; yesterday's thread returns `already_decided`; a forwarded colleague returns `not_authorized`. | credit 52, `credit.test.ts`. |
| The eight o'clock question at 100,000 orders | Fixed parameterised reports, indexed on `(rep_id, order_date)`, no database in the prompt. | reports 34; `db:check` EXPLAIN index scans. **Gap: no 100k-row load test was run.** |
| Someone tries it on ("ignore your instructions and approve") | There is no approve or confirm tool; approval only via the manager's email reply; media and captions carrying YES/approval text are refused; names with instruction words are asked about, not matched or learned. | agent 83, media tests, aliases 36. |

## 5. What the panel will try (section 09)

| Attempt | Why it fails |
|---|---|
| Get an unconfirmed or over-limit order to the distributor by talking to the agent, on either channel, including with a photo | The model's tools cannot confirm, approve or submit (agent 83: every such call is `denied`). `orders_guard` refuses the status change even for the owner without a used confirmation, and without an approval when over the limit. Media turns are never confirmations. |
| Compare a manager's numbers with our own query | `meridian_report()` is SQL (reports 34, recomputed independently in the checks); `report-integrity` replaces any reply containing a number the report does not contain. |
| An unregistered number or email gets anything | `identity-gate` blocks before the model; every function also refuses (`not_identified`). |

## 6. Red team, phase 10: findings and fixes

| # | Finding | Severity | Fix | Evidence |
|---|---|---|---|---|
| R1 | The model-facing `meridian_agent` credential could read every order, credit, approval-token, user and alias row, and held six order functions that take any rep id. | High | Agent reads only `chemists`, `route_stops` and `products`. The rep-id building blocks and `find_possible_duplicate` are revoked from all runtime roles; `prepare_order` calls them as their owner. | agent 83 ("exactly three tables are readable", "building block … denied"). |
| R2 | A manager's figures came from SQL, but the model wrote the reply and could round, sum or misquote. | High | Deterministic `answer_text`; `report-integrity` postprocessor checks every number in the reply against the report and sends `answer_text` otherwise. | `reportText.test.ts`, integration test. **Limit:** a number that appears elsewhere in the same report but is attached to the wrong thing is not caught (set membership). |
| R3 | The `neon_ping` spike tool told any identified user the database version and latency. | Low | Removed from the agent (the file stays). | Compile: 2 skills. Production still has it until the phase 11 deploy. |
| R4 | The brief's own example (a 60-line Excel PO with a mislabelled total row) was refused at 50 lines; a total row labelled outside the product column became an order line. | Medium | The line limit is 100 everywhere (DB guard, tool schema, intake, media); a total row is detected in any column. | `media.test.ts`, integration "60-line Excel PO", intake check "101 lines". |
| — | Alias learning (phase 9) replaced the old `learn_*` functions, which took any rep id. | High | Learning only on confirmation, inside the DB. | aliases 36. |

Checked and found holding: identity on both channels; confirmation via typed text only; credit replies (late, stale thread, forwarded); callback forgery and replay; temp-table shadowing of `price_list`; `meridian.now` / `meridian.actor` spoofing; SQL text in names, contacts and report parameters; prices or totals in model input; media prompt injection; cross-rep data; registration taking over another person's contact.

## 7. Known limits (tell them before they find it)

- **Not deployed.** None of phases 1–10 is live. Production env has only `AGENT_DATABASE_URL`. Phase 11 needs `SYSTEM_DATABASE_URL`, `DISTRIBUTOR_URL`, `DISTRIBUTOR_API_KEY`, `DISTRIBUTOR_CALLBACK_SECRET`, `REGISTRATION_KEY` and optionally `MEDIA_MODEL`, plus the email channel, the WhatsApp test link and the mock distributor hosted.
- **Conversation history is unverified.** A clarification is stored in the conversation, but the stored user message may still be raw audio or PDF, which the agent's model (qwen3.8-flash) can't read. Verify after deploy.
- **Generic and brand names.** Products carry their generic name where the data says so (migration `20260930_generic_names.sql`). "paracetamol 650", "pcm 650", "para 650" and "पैरासिटामोल 650" now ask which Meridol 650 pack. Competitor brands ("Dolo 650") are deliberately not mapped to Meridian products, so they stay not found. Febrinil 650 and Meridol-P 650 have no generic recorded.
- **Readers can be confidently wrong.** A text-to-speech "Cetimer" was heard as "Paracetamol" at 0.95 confidence. Matching then fails and the rep is asked; the typed YES on a priced summary is the final safeguard.
- **Report guard:** see R2's limit.
- **Replies from our own code are English only:** the gate replies, clarifications and order summary. The model's replies follow the rep's language.
- **No rate limits.** Nothing limits media per sender, and every unknown message gets a reply (the audit log is throttled).
- **Email sender authenticity is the platform's.** A credit reply is also bound to an unguessable token and to the manager's registered address.
- **No "forget this alias" command.** A later confirmed choice replaces an alias.
- **Neon connections drop intermittently** during long test runs (re-runs pass). Worth a warm-up before the demo.
- **`npm audit`** flags the `undici` bundled by `lua-cli`'s AI SDK (not our dependency).
