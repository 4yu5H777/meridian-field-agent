-- =============================================================================
-- Privilege checks AS meridian_readonly (the review panel).
--   node --env-file=.env scripts/db.mjs --as readonly db/checks-readonly.sql
-- Proves: the panel can read every table, view and read-only function, and
-- cannot write, even when it asks for a read-write transaction.
-- Non-zero exit if any check failed. Nothing is kept.
-- =============================================================================

-- Part 1: the role's default. Transactions are read-only unless asked otherwise.
BEGIN;
SET LOCAL search_path = meridian, public;
DO $$
DECLARE v_rows bigint;
BEGIN
  RAISE NOTICE 'connected as %', session_user;
  IF current_setting('transaction_read_only') <> 'on' THEN
    RAISE EXCEPTION 'FAIL  transactions are not read-only by default for this role';
  END IF;
  RAISE NOTICE 'PASS  transactions are read-only by default  ->  %', current_setting('transaction_read_only');

  SELECT (SELECT count(*) FROM meridian.orders) + (SELECT count(*) FROM meridian.user_contacts)
       + (SELECT count(*) FROM meridian.audit_log) + (SELECT count(*) FROM meridian.distributor_events)
       + (SELECT count(*) FROM meridian.v_orders) + (SELECT count(*) FROM meridian.v_chemist_credit)
    INTO v_rows;
  RAISE NOTICE 'PASS  reads tables and views, including contacts and audit  ->  % rows seen', v_rows;

  BEGIN
    INSERT INTO meridian.audit_log (actor, action) VALUES ('panel', 'x');
    RAISE EXCEPTION 'FAIL  insert was allowed in the default transaction';
  EXCEPTION WHEN read_only_sql_transaction THEN
    RAISE NOTICE 'PASS  insert in the default transaction  ->  %', SQLERRM;
  END;
END $$;
ROLLBACK;

-- Part 2: even in an explicit READ WRITE transaction, there is nothing to write with.
BEGIN READ WRITE;
SET LOCAL search_path = meridian, public;

CREATE TEMP TABLE check_results (name text, ok boolean) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_ok boolean;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL  %: statement was allowed', p_name;
    v_ok := false;
  EXCEPTION WHEN others THEN
    v_ok := (p_want = 'denied' AND SQLSTATE = '42501') OR (p_want = 'guard' AND SQLERRM LIKE 'GUARD:%');
    IF v_ok THEN RAISE NOTICE 'PASS  %  ->  %', p_name, SQLERRM;
    ELSE RAISE NOTICE 'FAIL  %: unexpected error [%] %', p_name, SQLSTATE, SQLERRM; END IF;
  END;
  INSERT INTO check_results VALUES (p_name, v_ok);
END $$;

CREATE FUNCTION pg_temp.expect_value(p_name text, p_got text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NOT DISTINCT FROM p_want THEN RAISE NOTICE 'PASS  %  ->  %', p_name, p_got;
  ELSE RAISE NOTICE 'FAIL  %: got %, want %', p_name, p_got, p_want; END IF;
  INSERT INTO check_results VALUES (p_name, p_got IS NOT DISTINCT FROM p_want);
END $$;

DO $t$
BEGIN
  RAISE NOTICE '--- read-only functions work ---';
  PERFORM pg_temp.expect_value('resolve a sender', (SELECT full_name FROM resolve_sender('whatsapp', '+919811042017')), 'Imran Qureshi');
  PERFORM pg_temp.expect_value('visibility function',
    (SELECT count(*)::text FROM visible_rep_ids((SELECT id FROM meridian.users WHERE employee_code = 'RH-NORTH'))), '50');
  PERFORM pg_temp.expect_value('matching function',
    (SELECT chemist_name FROM match_chemist((SELECT id FROM meridian.users WHERE employee_code = 'REP-NDL-01'), 'sharma ji') LIMIT 1),
    'Sharma Medical Store');

  RAISE NOTICE '--- no writes, even in a READ WRITE transaction ---';
  PERFORM pg_temp.expect_error('insert audit row', 'INSERT INTO meridian.audit_log (actor, action) VALUES (''panel'', ''x'')', 'denied');
  PERFORM pg_temp.expect_error('update an order', 'UPDATE meridian.orders SET status = ''cancelled''', 'denied');
  PERFORM pg_temp.expect_error('delete a ledger row', 'DELETE FROM meridian.credit_ledger', 'denied');
  PERFORM pg_temp.expect_error('truncate orders', 'TRUNCATE meridian.orders CASCADE', 'denied');
  PERFORM pg_temp.expect_error('create a table', 'CREATE TABLE meridian.x (id int)', 'denied');
  PERFORM pg_temp.expect_error('call a write function (build order)', 'SELECT meridian.create_draft_order(1, 1, ''whatsapp'', ''text'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (confirm)', 'SELECT * FROM meridian.confirm_order_by_code(''whatsapp'', ARRAY[''+919000000002''], ''1234'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (present)', 'SELECT * FROM meridian.present_order_for_confirmation(1, 1)', 'denied');
  PERFORM pg_temp.expect_error('call a write function (prepare order)', 'SELECT meridian.prepare_order(''email'', ARRAY[''x@y.example''], 1, ''[]'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (credit reply)', 'SELECT meridian.decide_credit_by_reply(ARRAY[''x@y.example''], ''CR-00000000'', ''approved'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (claim notifications)', 'SELECT * FROM meridian.claim_notifications(1, 60)', 'denied');
  PERFORM pg_temp.expect_error('call a write function (queue evening emails)', 'SELECT meridian.enqueue_evening_summaries(NULL)', 'denied');
  PERFORM pg_temp.expect_error('call the model-facing report function', 'SELECT meridian.meridian_report(''email'', ARRAY[''x@y.example''], ''orders_summary'', ''{}'')', 'denied');
  PERFORM pg_temp.expect_error('call the identity gate (writes audit)', 'SELECT meridian.screen_sender(''email'', ARRAY[''x@y.example''])', 'denied');
  PERFORM pg_temp.expect_error('register a contact', 'SELECT meridian.register_demo_contact(''manager'', ''email'', ''me@x.example'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (mark delivered)', 'SELECT meridian.mark_summaries_delivered(''email'', ARRAY[''x@y.example''], ''{}'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (approve)', 'SELECT meridian.decide_credit_approval(''x'', ''y@z.example'', ''approved'')', 'denied');
  PERFORM pg_temp.expect_error('call a write function (callback)', 'SELECT meridian.record_distributor_event(''e'', ''r'', ''ACCEPTED'', now(), ''{}'')', 'denied');
  PERFORM set_config('meridian.now', '2020-01-01 10:00+05:30', true);
  PERFORM pg_temp.expect_value('app_now() ignores meridian.now for the panel', (app_now() > now() - interval '1 minute')::text, 'true');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'readonly checks: % passed, % failed (plus 3 default-transaction checks above)', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% readonly check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
