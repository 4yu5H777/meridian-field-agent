-- =============================================================================
-- Privilege checks AS meridian_agent (the credential model-facing tools use).
--   node --env-file=.env scripts/db.mjs --as agent db/checks-agent.sql
-- Proves: every direct write is refused; the legitimate order workflow works
-- through the functions; system-only authority is out of reach; meridian.now
-- and meridian.actor cannot be abused. BEGIN ... ROLLBACK: nothing is kept.
-- Ends with an error (non-zero exit) if any check failed.
-- =============================================================================
BEGIN;
SET LOCAL search_path = meridian, public;

CREATE TEMP TABLE check_results (name text, ok boolean) ON COMMIT DROP;

-- p_want: 'denied' = no privilege (SQLSTATE 42501); 'guard' = a GUARD: rule error;
-- 'missing' = the function no longer exists (42883).
CREATE FUNCTION pg_temp.expect_error(p_name text, p_sql text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_ok boolean;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL  %: statement was allowed', p_name;
    v_ok := false;
  EXCEPTION WHEN others THEN
    v_ok := (p_want = 'denied' AND SQLSTATE = '42501') OR (p_want = 'guard' AND SQLERRM LIKE 'GUARD:%')
         OR (p_want = 'missing' AND SQLSTATE = '42883');
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
DECLARE
  -- Ids from what the agent may use: identify_sender for people, reference
  -- tables for chemists and products. Orders and approvals are unreadable to
  -- the agent (phase 10), so the refused-write checks below use a stand-in id:
  -- they are denied before any row is looked at.
  v_rep       bigint := (SELECT user_id FROM meridian.identify_sender('email', ARRAY['deepak.chauhan@meridian.example']));   -- Deepak
  v_other_rep bigint := (SELECT user_id FROM meridian.identify_sender('email', ARRAY['ravi.kumar@meridian.example']));       -- Ravi
  v_manager   bigint := (SELECT user_id FROM meridian.identify_sender('email', ARRAY['vikram.malhotra@meridian.example']));  -- Vikram
  v_chem      bigint := (SELECT id FROM meridian.chemists WHERE code = 'CH-10');              -- Deepak's, large limit
  v_foreign   bigint := (SELECT id FROM meridian.chemists WHERE code = 'CH-01');              -- Ravi's
  v_prod      bigint := (SELECT id FROM meridian.products WHERE sku = 'CET-10-10');
  v_prod2     bigint := (SELECT id FROM meridian.products WHERE sku = 'ORS-LEM-21');
  v_other_ord bigint := 1;
  v_pending   bigint := 1;
  v_order     bigint;
  v_code      text;
  v_intake    jsonb;
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  RAISE NOTICE '--- direct writes are refused ---';
  PERFORM pg_temp.expect_error('insert an order directly',
    format('INSERT INTO meridian.orders (rep_id, chemist_id, channel, input_type) VALUES (%s, %s, ''whatsapp'', ''text'')', v_rep, v_chem), 'denied');
  PERFORM pg_temp.expect_error('update an order status directly',
    format('UPDATE meridian.orders SET status = ''confirmed'' WHERE id = %s', v_pending), 'denied');
  PERFORM pg_temp.expect_error('approve credit directly',
    format('UPDATE meridian.credit_approvals SET status = ''approved'', decided_at = now(), decided_by_user_id = %s WHERE order_id = %s', v_manager, v_pending), 'denied');
  PERFORM pg_temp.expect_error('forge an approval row',
    format('INSERT INTO meridian.credit_approvals (order_id, manager_id, status, owed_paise_at_request, limit_paise_at_request, order_total_paise, decided_at, decided_by_user_id) VALUES (%s, %s, ''approved'', 0, 0, 0, now(), %s)', v_pending, v_manager, v_manager), 'denied');
  PERFORM pg_temp.expect_error('invent credit headroom with a ledger adjustment',
    format('INSERT INTO meridian.credit_ledger (chemist_id, entry_type, amount_paise, note) VALUES (%s, ''adjustment'', -100000000, ''x'')', v_chem), 'denied');
  PERFORM pg_temp.expect_error('raise a credit limit',
    'UPDATE meridian.chemists SET credit_limit_paise = 999999999', 'denied');
  PERFORM pg_temp.expect_error('change a list price',
    'UPDATE meridian.price_list SET unit_price_paise = 1', 'denied');
  PERFORM pg_temp.expect_error('insert an order line directly',
    format('INSERT INTO meridian.order_lines (order_id, line_no, product_id, qty) VALUES (%s, 99, %s, 1)', v_pending, v_prod), 'denied');
  PERFORM pg_temp.expect_error('delete audit rows', 'DELETE FROM meridian.audit_log', 'denied');
  PERFORM pg_temp.expect_error('truncate audit log', 'TRUNCATE meridian.audit_log', 'denied');
  PERFORM pg_temp.expect_error('truncate ledger', 'TRUNCATE meridian.credit_ledger', 'denied');
  PERFORM pg_temp.expect_error('truncate status history', 'TRUNCATE meridian.order_status_history', 'denied');
  PERFORM pg_temp.expect_error('create a table in meridian', 'CREATE TABLE meridian.x (id int)', 'denied');
  PERFORM pg_temp.expect_error('create a table in public', 'CREATE TABLE public.x (id int)', 'denied');

  RAISE NOTICE '--- data and authority the agent must not reach ---';
  PERFORM pg_temp.expect_error('read phone numbers and emails', 'SELECT count(*) FROM meridian.user_contacts', 'denied');
  PERFORM pg_temp.expect_error('read the audit log', 'SELECT count(*) FROM meridian.audit_log', 'denied');
  PERFORM pg_temp.expect_error('read distributor payloads', 'SELECT count(*) FROM meridian.distributor_events', 'denied');
  PERFORM pg_temp.expect_error('call the credit approval function',
    'SELECT meridian.decide_credit_approval(''CR-00000000'', ''vikram.malhotra@meridian.example'', ''approved'')', 'denied');
  PERFORM pg_temp.expect_error('call the distributor callback function',
    'SELECT meridian.record_distributor_event(''e'', ''r'', ''DISPATCHED'', now(), ''{}'')', 'denied');
  PERFORM pg_temp.expect_error('call the identity lookup', 'SELECT * FROM meridian.resolve_sender(''whatsapp'', ''+919811042017'')', 'denied');
  PERFORM pg_temp.expect_error('call an internal helper', format('SELECT meridian.assert_rep_owns_order(%s, %s)', v_rep, v_pending), 'denied');
  PERFORM pg_temp.expect_error('mark a callback as notified', 'SELECT meridian.mark_rep_notified(1)', 'denied');
  PERFORM pg_temp.expect_error('decide credit from a reply (system-only)', 'SELECT meridian.decide_credit_by_reply(ARRAY[''kavita.srivastava@meridian.example''], ''CR-00000000'', ''approved'')', 'denied');
  PERFORM pg_temp.expect_error('claim notifications (system-only)', 'SELECT * FROM meridian.claim_notifications(1, 60)', 'denied');
  PERFORM pg_temp.expect_error('complete a notification (system-only)', 'SELECT meridian.complete_notification(1, ''x'')', 'denied');
  PERFORM pg_temp.expect_error('read the notification outbox', 'SELECT count(*) FROM meridian.notification_outbox', 'denied');
  PERFORM pg_temp.expect_error('queue the evening emails (system-only)', 'SELECT meridian.enqueue_evening_summaries(NULL)', 'denied');
  PERFORM pg_temp.expect_value('team_report: a manager gets own-team figures',
    meridian.meridian_report('email', ARRAY['vikram.malhotra@meridian.example'], 'orders_summary', '{"period":"today"}')->>'scope', 'own team');
  PERFORM pg_temp.expect_value('team_report: an unknown sender gets nothing',
    meridian.meridian_report('email', ARRAY['stranger@gmail.com'], 'orders_summary', '{}')->>'error', 'not_identified');
  PERFORM pg_temp.expect_error('screen senders (identity gate, system-only)', 'SELECT meridian.screen_sender(''email'', ARRAY[''x@y.example''])', 'denied');
  PERFORM pg_temp.expect_error('register a contact as a demo person (system-only)', 'SELECT meridian.register_demo_contact(''manager'', ''email'', ''me@x.example'')', 'denied');
  PERFORM pg_temp.expect_error('read a manager''s evening summary directly', 'SELECT meridian.evening_summary(1, current_date)', 'denied');
  PERFORM pg_temp.expect_error('queue a notification directly', 'INSERT INTO meridian.notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload) VALUES (''credit_decision_to_rep'', ''x'', 1, ''email'', ''{}'')', 'denied');

  RAISE NOTICE '--- meridian.now and meridian.actor cannot be abused ---';
  PERFORM set_config('meridian.now', '2020-01-01 10:00+05:30', true);
  PERFORM pg_temp.expect_value('app_now() ignores meridian.now for the agent', (app_now() > now() - interval '1 minute')::text, 'true');
  PERFORM set_config('meridian.actor', 'user:' || v_manager, true);   -- pretend to be Vikram
  v_intake := prepare_order('email', ARRAY['deepak.chauhan@meridian.example'], v_chem,
                            jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 10, 'raw_text', 'cetimer 10'),
                                              jsonb_build_object('product_id', v_prod, 'qty', 2)), 'text', 'privilege-check');
  v_order := (v_intake->>'order_id')::bigint;
  v_code  := v_intake->'summary'->'confirmation'->>'code';
  PERFORM set_config('meridian.now', '', true);
  PERFORM set_config('meridian.actor', '', true);

  RAISE NOTICE '--- the only order path is prepare_order, for the rep resolved from contacts ---';
  PERFORM pg_temp.expect_value('same product twice is one line, priced from the list (Rs 20.00), not the caller',
    (SELECT string_agg((l->>'qty') || ' @ ' || (l->>'unit_price_paise'), ',') FROM jsonb_array_elements(v_intake->'summary'->'lines') l), '12 @ 2000');
  PERFORM pg_temp.expect_value('the summary comes back with a 4-digit code', (v_code ~ '^[0-9]{4}$')::text, 'true');
  PERFORM pg_temp.expect_error('building block: create a draft for any rep id',
    format('SELECT meridian.create_draft_order(%s, %s, ''whatsapp'', ''text'')', v_rep, v_chem), 'denied');
  PERFORM pg_temp.expect_error('building block: set a line on any order',
    format('SELECT meridian.set_order_line(%s, %s, %s, 1)', v_rep, v_order, v_prod), 'denied');
  PERFORM pg_temp.expect_error('building block: remove a line',
    format('SELECT meridian.remove_order_line(%s, %s, %s)', v_rep, v_order, v_prod), 'denied');
  PERFORM pg_temp.expect_error('building block: present for confirmation',
    format('SELECT * FROM meridian.present_order_for_confirmation(%s, %s)', v_rep, v_order), 'denied');
  PERFORM pg_temp.expect_error('building block: return to draft',
    format('SELECT meridian.return_order_to_draft(%s, %s)', v_rep, v_order), 'denied');
  PERFORM pg_temp.expect_error('building block: cancel any order',
    format('SELECT meridian.cancel_order(%s, %s)', v_rep, v_order), 'denied');
  PERFORM pg_temp.expect_error('duplicate lookup by order id (panel only)', format('SELECT * FROM meridian.find_possible_duplicate(%s)', v_order), 'denied');

  RAISE NOTICE '--- attack: the agent confirms on the rep''s behalf ---';
  PERFORM pg_temp.expect_error('the old confirm_order_by_rep path is gone',
    format('SELECT * FROM meridian.confirm_order_by_rep(%s, %s)', v_rep, v_order), 'missing');
  PERFORM pg_temp.expect_error('call confirm_order_by_code with the code it was just given',
    format('SELECT * FROM meridian.confirm_order_by_code(''email'', ARRAY[''deepak.chauhan@meridian.example''], %L)', v_code), 'denied');
  PERFORM pg_temp.expect_error('read confirmation codes', 'SELECT count(*) FROM meridian.order_confirmations', 'denied');
  PERFORM pg_temp.expect_error('mark a confirmation request used',
    'UPDATE meridian.order_confirmations SET status = ''used''', 'denied');
  PERFORM pg_temp.expect_error('submit the presented, unconfirmed order',
    format('SELECT meridian.submit_order(%s, ''MER-ORDER-%s'', ''PRIV-AGENT-X'')', v_order, v_order), 'denied');
  PERFORM pg_temp.expect_value('it is still waiting for the rep''s typed YES',
    (SELECT count(*)::text FROM live_order_summaries('email', ARRAY['deepak.chauhan@meridian.example']) WHERE order_id = v_order), '1');

  RAISE NOTICE '--- no rep''s data is readable with the agent credential ---';
  PERFORM pg_temp.expect_error('read orders', 'SELECT count(*) FROM meridian.orders', 'denied');
  PERFORM pg_temp.expect_error('read order lines', 'SELECT count(*) FROM meridian.order_lines', 'denied');
  PERFORM pg_temp.expect_error('read the credit ledger', 'SELECT count(*) FROM meridian.credit_ledger', 'denied');
  PERFORM pg_temp.expect_error('read credit approvals (tokens)', 'SELECT count(*) FROM meridian.credit_approvals', 'denied');
  PERFORM pg_temp.expect_error('read order history', 'SELECT count(*) FROM meridian.order_status_history', 'denied');
  PERFORM pg_temp.expect_error('read users', 'SELECT count(*) FROM meridian.users', 'denied');
  PERFORM pg_temp.expect_error('read the reporting view', 'SELECT count(*) FROM meridian.v_orders', 'denied');
  PERFORM pg_temp.expect_error('read chemist credit', 'SELECT count(*) FROM meridian.v_chemist_credit', 'denied');
  PERFORM pg_temp.expect_error('read other reps'' learned aliases', 'SELECT count(*) FROM meridian.product_aliases', 'denied');
  PERFORM pg_temp.expect_error('read the price list directly', 'SELECT count(*) FROM meridian.price_list', 'denied');
  PERFORM pg_temp.expect_value('exactly three tables are readable',
    (SELECT string_agg(c.relname, ',' ORDER BY c.relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'meridian' AND c.relkind IN ('r', 'v') AND has_table_privilege(c.oid, 'SELECT')), 'chemists,products,route_stops');
  -- Aliases are learned only by the database, from a confirmed order (section 18).
  PERFORM pg_temp.expect_error('write a chemist alias directly',
    format('INSERT INTO meridian.chemist_aliases (chemist_id, alias, rep_id, source) VALUES (%s, ''singh ji'', %s, ''learned'')', v_chem, v_rep), 'denied');
  PERFORM pg_temp.expect_error('write a product alias directly',
    format('INSERT INTO meridian.product_aliases (product_id, alias, rep_id, source) VALUES (%s, ''cet 10'', %s, ''learned'')', v_prod, v_rep), 'denied');
  PERFORM pg_temp.expect_error('learn a product alias through the learning function',
    format('SELECT meridian.learn_product_alias_from_line(%s, %s, ''cet 10'', 1)', v_rep, v_prod), 'denied');
  PERFORM pg_temp.expect_error('learn a chemist alias through the learning function',
    format('SELECT meridian.learn_chemist_alias_from_order(%s, %s, ''singh ji'', 1)', v_rep, v_chem), 'denied');
  PERFORM pg_temp.expect_value('no alias-learning function is executable by the agent',
    (SELECT count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'meridian' AND p.proname LIKE 'learn%' AND has_function_privilege(p.oid, 'EXECUTE')), '0');

  RAISE NOTICE '--- order intake and summary integrity (identity from contacts, no rep id) ---';
  PERFORM pg_temp.expect_value('identify_sender for a seeded rep email',
    (SELECT result || '/' || role FROM identify_sender('email', ARRAY['deepak.chauhan@meridian.example'])), 'ok/rep');
  v_intake := prepare_order('email', ARRAY['deepak.chauhan@meridian.example'], v_chem,
                            jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 3)), 'text', 'privilege-check');
  PERFORM pg_temp.expect_value('agent can prepare an order for the identified rep',
    (v_intake->'summary'->>'status'), 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('... which replaces his earlier unconfirmed summary for that chemist',
    (v_intake->'superseded_order_ids')::text, format('[%s]', v_order));
  PERFORM pg_temp.expect_value('the summary comes back with a live code',
    ((v_intake->'summary'->'confirmation'->>'code') ~ '^[0-9]{4}$')::text, 'true');
  PERFORM pg_temp.expect_value('agent can list the rep''s live summaries',
    (SELECT count(*)::text FROM live_order_summaries('email', ARRAY['deepak.chauhan@meridian.example'])
      WHERE order_id = (v_intake->>'order_id')::bigint), '1');
  PERFORM pg_temp.expect_error('call the internal order_summary directly',
    format('SELECT meridian.order_summary(%s)', v_intake->>'order_id'), 'denied');
  PERFORM pg_temp.expect_error('prepare an order for an unidentified sender',
    format('SELECT meridian.prepare_order(''email'', ARRAY[''nobody@example.com''], %s, ''[{"product_id": %s, "qty": 1}]'')', v_chem, v_prod), 'guard');

  RAISE NOTICE '--- acting outside the rep''s own scope is refused ---';
  PERFORM pg_temp.expect_error('order for another rep''s chemist',
    format('SELECT meridian.prepare_order(''email'', ARRAY[''deepak.chauhan@meridian.example''], %s, ''[{"product_id": %s, "qty": 1}]'')', v_foreign, v_prod), 'guard');
  PERFORM pg_temp.expect_error('a manager cannot place an order',
    format('SELECT meridian.prepare_order(''email'', ARRAY[''vikram.malhotra@meridian.example''], %s, ''[{"product_id": %s, "qty": 1}]'')', v_chem, v_prod), 'guard');
  PERFORM pg_temp.expect_error('a price in the line is ignored, a bad qty refused',
    format('SELECT meridian.prepare_order(''email'', ARRAY[''deepak.chauhan@meridian.example''], %s, ''[{"product_id": %s, "qty": 0, "unit_price_paise": 1}]'')', v_chem, v_prod), 'guard');
  PERFORM pg_temp.expect_value('Ravi''s id is known only through his contacts', (v_other_rep IS NOT NULL)::text, 'true');

  RAISE NOTICE '--- attack: push the over-limit order through ---';
  PERFORM pg_temp.expect_error('submit the order that is waiting for credit approval',
    format('SELECT meridian.submit_order(%s, ''MER-ORDER-%s'', ''XREF'')', v_pending, v_pending), 'denied');
  PERFORM pg_temp.expect_error('claim orders for submission', 'SELECT * FROM meridian.claim_submissions(1, 60)', 'denied');
  PERFORM pg_temp.expect_error('the old placeholder is gone', format('SELECT meridian.mark_order_submitted(%s, ''X'')', v_pending), 'missing');
  PERFORM pg_temp.expect_error('queue an order for submission directly', format('INSERT INTO meridian.distributor_submissions (order_id, idempotency_key) VALUES (%s, ''X'')', v_pending), 'denied');
  PERFORM pg_temp.expect_error('present it again to get a fresh code',
    format('SELECT * FROM meridian.present_order_for_confirmation(%s, %s)', v_rep, v_pending), 'denied');
  PERFORM pg_temp.expect_error('reopen it as a draft to edit it',
    format('SELECT meridian.return_order_to_draft(%s, %s)', v_rep, v_pending), 'denied');

  RAISE NOTICE '--- attack: shadow a table with a temp table ---';
  CREATE TEMP TABLE price_list (id bigint, product_id bigint, unit_price_paise bigint, effective_from date, effective_to date);
  INSERT INTO pg_temp.price_list VALUES (1, v_prod, 1, '2000-01-01', NULL);
  v_intake := prepare_order('email', ARRAY['deepak.chauhan@meridian.example'], v_chem,
                            jsonb_build_array(jsonb_build_object('product_id', v_prod, 'qty', 3)), 'text', 'shadow-check');
  PERFORM pg_temp.expect_value('pricing ignores a temp price_list in the caller''s session',
    (SELECT l->>'unit_price_paise' FROM jsonb_array_elements(v_intake->'summary'->'lines') l), '2000');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'agent checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% agent check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
