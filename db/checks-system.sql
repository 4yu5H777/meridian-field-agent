-- =============================================================================
-- Privilege checks AS meridian_system (identity preprocessor, approval email
-- handler, distributor webhook, jobs: code the model cannot call).
--   node --env-file=.env scripts/db.mjs --as system db/checks-system.sql
-- Proves: the system-only operations work, the approval rules still apply to
-- them, and this role cannot write tables directly either.
-- BEGIN ... ROLLBACK: nothing is kept. Non-zero exit if any check failed.
-- =============================================================================
BEGIN;
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
DECLARE
  a           meridian.credit_approvals;
  v_mgr_email text;
  v_mgr_name  text;
  v_ref       text;
  v_evt       bigint;
  v_neha      text;
  v_bad       text;
BEGIN
  SELECT * INTO a FROM meridian.credit_approvals WHERE status = 'pending' ORDER BY requested_at LIMIT 1;
  SELECT uc.value, u.full_name INTO v_mgr_email, v_mgr_name
    FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE uc.user_id = a.manager_id AND uc.channel = 'email' AND uc.valid_to IS NULL;
  RAISE NOTICE 'connected as %', session_user;

  RAISE NOTICE '--- identity (runs before the model sees a message) ---';
  PERFORM pg_temp.expect_value('Imran''s current number resolves to him',
    (SELECT full_name FROM resolve_sender('whatsapp', '+91 98110 42017')), 'Imran Qureshi');
  PERFORM pg_temp.expect_value('Imran''s retired number resolves to nobody',
    (SELECT count(*)::text FROM resolve_sender('whatsapp',
       (SELECT value FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
         WHERE u.employee_code = 'REP-NDL-02' AND uc.channel = 'whatsapp' AND uc.valid_to IS NOT NULL))), '0');
  PERFORM log_unknown_sender('whatsapp', '+91 99999 00000');
  PERFORM pg_temp.expect_value('unknown sender is logged, with the real login',
    (SELECT actor || ' / ' || db_role FROM meridian.audit_log WHERE action = 'identity.unknown_sender' ORDER BY id DESC LIMIT 1),
    'unknown:+919999900000 / meridian_system');

  RAISE NOTICE '--- credit approval by email reply ---';
  PERFORM set_approval_email_id(a.id, '<' || a.token || '@meridian.example>');
  PERFORM pg_temp.expect_value('approval email Message-ID recorded',
    (SELECT email_message_id FROM meridian.credit_approvals WHERE id = a.id), '<' || a.token || '@meridian.example>');
  PERFORM pg_temp.expect_value('reply from a colleague who is not the approver',
    decide_credit_approval(a.token, 'pooja.bhatia@meridian.example', 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('reply from the approver on record (' || v_mgr_name || ')',
    decide_credit_approval(a.token, upper(v_mgr_email), 'approved', 'ok'), 'approved');
  PERFORM pg_temp.expect_value('order moved to confirmed',
    (SELECT status FROM meridian.orders WHERE id = a.order_id), 'confirmed');
  PERFORM pg_temp.expect_value('history: actor is the manager, db_role is the system login',
    (SELECT actor || ' / ' || db_role FROM meridian.order_status_history
      WHERE order_id = a.order_id AND to_status = 'confirmed'), 'user:' || a.manager_id || ' / meridian_system');
  PERFORM pg_temp.expect_value('a second reply changes nothing',
    decide_credit_approval(a.token, v_mgr_email, 'rejected'), 'already_decided');

  RAISE NOTICE '--- submission and distributor callbacks ---';
  v_ref := 'PRIV-SYS-' || a.order_id;
  PERFORM pg_temp.expect_value('approved order claimed for submission by the system role',
    (SELECT idempotency_key FROM claim_submissions(10, 60) WHERE order_id = a.order_id), 'MER-ORDER-' || a.order_id);
  PERFORM pg_temp.expect_value('system records the distributor ref', submit_order(a.order_id, 'MER-ORDER-' || a.order_id, v_ref), 'submitted');
  PERFORM pg_temp.expect_value('approved order can be submitted',
    (SELECT status FROM meridian.orders WHERE id = a.order_id), 'submitted');
  PERFORM pg_temp.expect_value('callback ACCEPTED is applied',
    record_distributor_event('PRIV-EVT-1', v_ref, 'ACCEPTED', now(), '{}'), 'applied');
  PERFORM pg_temp.expect_value('the same callback again is a duplicate',
    record_distributor_event('PRIV-EVT-1', v_ref, 'ACCEPTED', now(), '{}'), 'duplicate');
  SELECT id INTO v_evt FROM meridian.distributor_events WHERE distributor_event_id = 'PRIV-EVT-1';
  PERFORM pg_temp.expect_value('first notification claim succeeds', mark_rep_notified(v_evt)::text, 'true');
  PERFORM pg_temp.expect_value('second notification claim is refused', mark_rep_notified(v_evt)::text, 'false');

  RAISE NOTICE '--- notifications and credit replies (the dispatcher job and the credit-reply gate) ---';
  PERFORM pg_temp.expect_value('system claims the rep notifications queued above (credit decision, then the applied callback)',
    (SELECT string_agg(kind, ',') FROM claim_notifications(5, 60)), 'credit_decision_to_rep,order_status_to_rep');
  PERFORM pg_temp.expect_value('a reply from an unknown address decides nothing',
    decide_credit_by_reply(ARRAY['boss@gmail.com'], a.token, 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_error('write the outbox directly', 'UPDATE meridian.notification_outbox SET status = ''sent''', 'denied');
  PERFORM pg_temp.expect_value('system queues the 7 PM emails (8 managers + regional head)', enqueue_evening_summaries(NULL)::text, '9');
  PERFORM pg_temp.expect_error('but cannot read a summary directly', 'SELECT meridian.evening_summary(1, current_date)', 'denied');
  PERFORM pg_temp.expect_error('the model-facing report function (agent-only)', 'SELECT meridian.meridian_report(''email'', ARRAY[''x@y.example''], ''orders_summary'', ''{}'')', 'denied');
  PERFORM pg_temp.expect_value('identity gate: a registered manager is let through, role only',
    screen_sender('email', ARRAY['vikram.malhotra@meridian.example'])::text, '{"role": "area_manager", "result": "ok"}');
  PERFORM pg_temp.expect_value('identity gate: a stranger gets unknown_sender and nothing else',
    screen_sender('whatsapp', ARRAY['+91 88888 00000'])::text, '{"result": "unknown_sender"}');
  PERFORM pg_temp.expect_value('identity gate: the refusal is logged with the real login',
    (SELECT actor || ' / ' || db_role || ' / ' || (details->>'reason') FROM meridian.audit_log WHERE action = 'identity.unknown_sender' ORDER BY id DESC LIMIT 1),
    'unknown:+918888800000 / meridian_system / unknown_sender');
  PERFORM pg_temp.expect_value('registration: the system role can put a reviewer contact on the demo rep',
    register_demo_contact('rep', 'email', 'reviewer@example.org')->>'as', 'Deepak Chauhan');

  RAISE NOTICE '--- the system role cannot write tables directly either ---';
  PERFORM pg_temp.expect_error('update an order directly',
    format('UPDATE meridian.orders SET status = ''dispatched'' WHERE id = %s', a.order_id), 'denied');
  PERFORM pg_temp.expect_error('insert a ledger entry directly',
    'INSERT INTO meridian.credit_ledger (chemist_id, entry_type, amount_paise) VALUES (1, ''payment'', -100)', 'denied');
  PERFORM pg_temp.expect_error('rewrite an approval directly',
    format('UPDATE meridian.credit_approvals SET status = ''rejected'' WHERE id = %s', a.id), 'denied');
  PERFORM pg_temp.expect_error('add a contact directly (register a phone)',
    'INSERT INTO meridian.user_contacts (user_id, channel, value) VALUES (1, ''whatsapp'', ''+919000000999'')', 'denied');
  PERFORM pg_temp.expect_error('truncate distributor events', 'TRUNCATE meridian.distributor_events', 'denied');
  PERFORM pg_temp.expect_error('build orders (agent-only)',
    'SELECT meridian.create_draft_order(1, 1, ''whatsapp'', ''text'')', 'denied');
  PERFORM pg_temp.expect_error('prepare an order (agent-only)',
    'SELECT meridian.prepare_order(''email'', ARRAY[''x@y.example''], 1, ''[]'')', 'denied');
  PERFORM pg_temp.expect_error('read a rep''s live summaries (agent-only)',
    'SELECT * FROM meridian.live_order_summaries(''email'', ARRAY[''x@y.example''])', 'denied');
  PERFORM pg_temp.expect_error('show a summary / issue a code (agent-only)',
    'SELECT * FROM meridian.present_order_for_confirmation(1, 1)', 'denied');
  PERFORM pg_temp.expect_error('forge a used confirmation request directly',
    'INSERT INTO meridian.order_confirmations (order_id, rep_id, code, total_paise, lines_hash, expires_at) VALUES (1, 1, ''1234'', 1, ''x'', now() + interval ''1 hour'')', 'denied');

  RAISE NOTICE '--- rep confirmation by code (the preprocessor''s call) ---';
  -- Neha (REP-GGN-01) has a presented order in the seed. Whether its code has
  -- expired depends on when the seed ran, so only outcomes that do not depend
  -- on the clock are checked here; checks-confirmation.sql covers the rest.
  SELECT uc.value INTO v_neha FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = 'REP-GGN-01' AND uc.channel = 'whatsapp' AND uc.valid_to IS NULL;
  SELECT lpad(n::text, 4, '0') INTO v_bad FROM generate_series(0, 9999) AS n
   WHERE lpad(n::text, 4, '0') NOT IN (SELECT code FROM meridian.order_confirmations
                                        WHERE rep_id = (SELECT id FROM meridian.users WHERE employee_code = 'REP-GGN-01'))
   LIMIT 1;
  PERFORM pg_temp.expect_value('unknown number',
    (SELECT result FROM confirm_order_by_code('whatsapp', ARRAY['+919999955555'], '1234')), 'unknown_sender');
  PERFORM pg_temp.expect_value('a manager is not a rep',
    (SELECT result FROM confirm_order_by_code('email', ARRAY[v_mgr_email], '1234')), 'not_a_rep');
  PERFORM pg_temp.expect_value('two people''s numbers in one profile',
    (SELECT result FROM confirm_order_by_code('whatsapp', ARRAY[v_neha, '+919811042017'], '1234')), 'ambiguous_sender');
  PERFORM pg_temp.expect_value('not a 4-digit code',
    (SELECT result FROM confirm_order_by_code('whatsapp', ARRAY[v_neha], 'yes')), 'invalid_code');
  PERFORM pg_temp.expect_value('a code Neha was never given',
    (SELECT result FROM confirm_order_by_code('whatsapp', ARRAY[v_neha], v_bad)), 'wrong_code');
  PERFORM pg_temp.expect_value('refusals are audited with the system login',
    (SELECT count(*)::text FROM meridian.audit_log WHERE action = 'confirmation.refused' AND db_role = 'meridian_system'
       AND occurred_at >= now() - interval '1 minute'), '5');
  PERFORM set_config('meridian.now', '2020-01-01 10:00+05:30', true);
  PERFORM pg_temp.expect_value('app_now() ignores meridian.now for the system role',
    (app_now() > now() - interval '1 minute')::text, 'true');
  PERFORM set_config('meridian.now', '', true);
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'system checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% system check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
