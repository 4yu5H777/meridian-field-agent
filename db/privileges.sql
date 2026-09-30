-- =============================================================================
-- Meridian grants. Run after schema.sql (and seed.sql) on every reset: dropping
-- the schema drops every grant on its objects, while the roles themselves
-- (roles.sql) survive.
--
-- The rule: runtime roles never get INSERT, UPDATE, DELETE or TRUNCATE on any
-- table. Nothing below grants them, and the REVOKEs make that explicit. Writes
-- happen only inside the SECURITY DEFINER functions of schema.sql, each granted
-- to the role that legitimately needs it.
-- =============================================================================
SET ROLE meridian_owner;
SET search_path = meridian, public;

-- Start from nothing.
REVOKE ALL ON SCHEMA meridian FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA meridian FROM PUBLIC, meridian_agent, meridian_system, meridian_readonly;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA meridian FROM PUBLIC, meridian_agent, meridian_system, meridian_readonly;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA meridian FROM PUBLIC, meridian_agent, meridian_system, meridian_readonly;

GRANT USAGE ON SCHEMA meridian TO meridian_agent, meridian_system, meridian_readonly;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
-- Agent: ONLY the reference rows order intake reads directly (a rep's chemist
-- by id, a product by id). Orders, lines, credit, users, contacts, aliases and
-- the reporting views are not readable at all: every model-facing answer goes
-- through a SECURITY DEFINER function that resolves the sender from their
-- contacts and scopes the rows itself (prepare_order, live_order_summaries,
-- meridian_report). A leaked AGENT_DATABASE_URL therefore reads no order,
-- credit or personal data of any rep. (Red team, phase 10.)
GRANT SELECT ON chemists, route_stops, products TO meridian_agent;

-- System (identity, notifications, approval emails, jobs) and the panel read everything.
GRANT SELECT ON ALL TABLES IN SCHEMA meridian TO meridian_system, meridian_readonly;

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------
-- Pure helpers and read-only calculations: everyone. app_now() ignores
-- meridian.now for these roles (see schema.sql).
GRANT EXECUTE ON FUNCTION
  app_now(), ist_date(timestamptz), rupees(bigint), normalize_name(text), normalize_contact(text, text),
  order_transition_allowed(text, text), order_total_paise(bigint), chemist_owed_paise(bigint),
  order_lines_hash(bigint), order_lines_signature(bigint), visible_rep_ids(bigint)
  TO meridian_agent, meridian_system, meridian_readonly;

-- Matching: the agent (intake, with the rep id that identify_sender resolved)
-- and the panel, to reproduce results. Duplicate lookup: panel only (prepare_order
-- runs it internally).
GRANT EXECUTE ON FUNCTION match_chemist(bigint, text), match_product(bigint, text)
  TO meridian_agent, meridian_readonly;
GRANT EXECUTE ON FUNCTION find_possible_duplicate(bigint) TO meridian_readonly;

-- Identity lookup reads user_contacts: system (the preprocessor) and the panel.
GRANT EXECUTE ON FUNCTION resolve_sender(text, text) TO meridian_system, meridian_readonly;

-- The rep-id order building blocks (create_draft_order, set_order_line,
-- remove_order_line, present_order_for_confirmation, return_order_to_draft,
-- cancel_order) take a rep id from the caller, so they are NOT granted to any
-- runtime role: prepare_order calls them as their owner, for the rep it
-- resolved from the sender's contacts. (Red team, phase 10.)

-- Order intake (prepare_order tool) and summary integrity (postprocessor).
-- Each resolves the sender from the contacts the platform supplied; none takes
-- a rep id. order_summary() stays internal: it is reachable only through these.
GRANT EXECUTE ON FUNCTION
  identify_sender(text, text[]),
  prepare_order(text, text[], bigint, jsonb, text, text, text),
  live_order_summaries(text, text[]),
  mark_summaries_delivered(text, text[], bigint[]),
  meridian_report(text, text[], text, jsonb)
  TO meridian_agent;

-- Submission to the distributor: the distributor-submitter job only (system).
-- The agent role has no way to submit an order.
GRANT EXECUTE ON FUNCTION
  claim_submissions(integer, integer),
  enqueue_evening_summaries(date),
  submit_order(bigint, text, text),
  fail_submission(bigint, text)
  TO meridian_system;

-- Authority the model must never reach: a rep's confirmation (from the
-- sender's verified contacts), approving credit, recording distributor
-- callbacks, and the bookkeeping around them. System only.
GRANT EXECUTE ON FUNCTION
  confirm_order_by_code(text, text[], text),
  decide_credit_by_reply(text[], text, text, text),
  claim_notifications(integer, integer),
  complete_notification(bigint, text),
  fail_notification(bigint, text),
  decide_credit_approval(text, text, text, text),
  record_distributor_event(text, text, text, timestamptz, jsonb),
  set_approval_email_id(bigint, text),
  mark_rep_notified(bigint),
  log_unknown_sender(text, text),
  screen_sender(text, text[], text),
  register_demo_contact(text, text, text, boolean)
  TO meridian_system;

RESET ROLE;

-- What each runtime role can now do, for the record.
SELECT r.rolname AS role,
       (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'meridian'::regnamespace AND c.relkind IN ('r', 'v')
          AND has_table_privilege(r.rolname, c.oid, 'SELECT')) AS readable,
       (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'meridian'::regnamespace AND c.relkind = 'r'
          AND (has_table_privilege(r.rolname, c.oid, 'INSERT') OR has_table_privilege(r.rolname, c.oid, 'UPDATE')
               OR has_table_privilege(r.rolname, c.oid, 'DELETE') OR has_table_privilege(r.rolname, c.oid, 'TRUNCATE'))) AS writable,
       (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'meridian'::regnamespace
          AND has_function_privilege(r.rolname, p.oid, 'EXECUTE')) AS executable_functions
FROM pg_roles r WHERE r.rolname IN ('meridian_agent', 'meridian_system', 'meridian_readonly') ORDER BY 1;
