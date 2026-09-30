-- =============================================================================
-- Confirmation binding: end-to-end tests of the rule "only the verified rep's
-- explicit yes to the exact current summary can unlock submission".
--   node --env-file=.env.owner scripts/db.mjs db/checks-confirmation.sql
-- Runs as the owner login so one transaction can play every part: the agent
-- showing a summary, the preprocessor passing on "YES <code>" from a sender's
-- contacts, and the clock moving past an expiry (meridian.now is honoured only
-- for this login). Which ROLE may call which function is proven separately in
-- checks-agent.sql / checks-system.sql / checks-readonly.sql.
-- BEGIN ... ROLLBACK: nothing is kept. Non-zero exit if any check failed.
-- =============================================================================
BEGIN;
SET LOCAL search_path = meridian, public;

CREATE TEMP TABLE check_results (name text, ok boolean) ON COMMIT DROP;

CREATE FUNCTION pg_temp.expect_value(p_name text, p_got text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NOT DISTINCT FROM p_want THEN RAISE NOTICE 'PASS  %  ->  %', p_name, p_got;
  ELSE RAISE NOTICE 'FAIL  %: got %, want %', p_name, p_got, p_want; END IF;
  INSERT INTO check_results VALUES (p_name, p_got IS NOT DISTINCT FROM p_want);
END $$;

-- The statement must be refused by a rule: a GUARD: trigger error, or a
-- CHECK (23514) / unique (23505) constraint.
CREATE FUNCTION pg_temp.expect_refused(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_ok boolean;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL  %: statement was allowed', p_name;
    v_ok := false;
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'GUARD:%' OR SQLSTATE IN ('23514', '23505');
    IF v_ok THEN RAISE NOTICE 'PASS  %  ->  %', p_name, SQLERRM;
    ELSE RAISE NOTICE 'FAIL  %: unexpected error [%] %', p_name, SQLSTATE, SQLERRM; END IF;
  END;
  INSERT INTO check_results VALUES (p_name, v_ok);
END $$;

-- The rep's current contact on a channel, as the channel would hand it over.
CREATE FUNCTION pg_temp.contact(p_emp text, p_channel text) RETURNS text
LANGUAGE sql AS $$
  SELECT uc.value FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = p_emp AND uc.channel = p_channel AND uc.valid_to IS NULL
$$;

-- A 4-digit code this rep has never been issued, so a "wrong code" test can
-- never collide with a real one.
CREATE FUNCTION pg_temp.unused_code(p_rep bigint) RETURNS text
LANGUAGE sql AS $$
  SELECT lpad(n::text, 4, '0') FROM generate_series(0, 9999) AS n
   WHERE lpad(n::text, 4, '0') NOT IN (SELECT code FROM meridian.order_confirmations WHERE rep_id = p_rep)
   LIMIT 1
$$;

CREATE FUNCTION pg_temp.confirm(p_contact text, p_code text, p_channel text DEFAULT 'whatsapp') RETURNS text
LANGUAGE sql AS $$
  SELECT result FROM meridian.confirm_order_by_code(p_channel, ARRAY[p_contact], p_code)
$$;

DO $t$
DECLARE
  v_deepak   bigint := (SELECT id FROM users WHERE employee_code = 'REP-NOI-01');
  v_ravi     bigint := (SELECT id FROM users WHERE employee_code = 'REP-NDL-01');
  v_neha     bigint := (SELECT id FROM users WHERE employee_code = 'REP-GGN-01');
  w_deepak   text   := pg_temp.contact('REP-NOI-01', 'whatsapp');
  w_ravi     text   := pg_temp.contact('REP-NDL-01', 'whatsapp');
  w_neha     text   := pg_temp.contact('REP-GGN-01', 'whatsapp');
  e_deepak   text   := pg_temp.contact('REP-NOI-01', 'email');
  v_ch10     bigint := (SELECT id FROM chemists WHERE code = 'CH-10');   -- Deepak's, large limit
  v_ch01     bigint := (SELECT id FROM chemists WHERE code = 'CH-01');   -- Ravi's
  v_ch03     bigint := (SELECT id FROM chemists WHERE code = 'CH-03');   -- Ravi's, already over its limit
  v_ch14     bigint := (SELECT id FROM chemists WHERE code = 'CH-14');   -- Neha's
  p_cet      bigint := (SELECT id FROM products WHERE sku = 'CET-10-10');
  p_ors      bigint := (SELECT id FROM products WHERE sku = 'ORS-LEM-21');
  p_mul      bigint := (SELECT id FROM products WHERE sku = 'MUL-15');
  v_a        bigint;   -- Deepak's order: the happy path
  v_b        bigint;   -- Ravi's order: another rep's code, lockout
  v_c        bigint;   -- Neha's order: expiry
  v_d        bigint;   -- Ravi's order at New Life: over credit
  v_code_a1  text;
  v_code_a2  text;
  v_code_b   text;
  v_code_c   text;
  v_code_d   text;
  v_conf_a   bigint;
  v_i        int;
  r          record;
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- showing the summary freezes it and issues a code ---';
  v_a := create_draft_order(v_deepak, v_ch10, 'whatsapp', 'text', 'confirmation-check');
  PERFORM set_order_line(v_deepak, v_a, p_cet, 10);
  PERFORM set_order_line(v_deepak, v_a, p_ors, 6);
  SELECT * INTO r FROM present_order_for_confirmation(v_deepak, v_a);
  v_i := 0;
  -- The cross-rep tests below need Deepak's code to be one Ravi has never had.
  WHILE r.confirmation_code IN (SELECT code FROM order_confirmations WHERE rep_id = v_ravi) AND v_i < 20 LOOP
    SELECT * INTO r FROM present_order_for_confirmation(v_deepak, v_a);
    v_i := v_i + 1;
  END LOOP;
  v_code_a1 := r.confirmation_code;
  PERFORM pg_temp.expect_value('code is 4 digits', (v_code_a1 ~ '^[0-9]{4}$')::text, 'true');
  PERFORM pg_temp.expect_value('frozen total = order total now', (r.total_paise = order_total_paise(v_a))::text, 'true');
  PERFORM pg_temp.expect_value('frozen fingerprint = lines now',
    (SELECT (lines_hash = order_lines_hash(v_a))::text FROM order_confirmations WHERE order_id = v_a AND status = 'pending'), 'true');
  PERFORM pg_temp.expect_value('expires in 30 minutes', (r.expires_at = app_now() + interval '30 minutes')::text, 'true');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- a yes that does not come through a code is not a confirmation ---';
  PERFORM pg_temp.expect_refused('owner sets confirmed + snapshot by hand, no request',
    format($q$UPDATE orders SET status = 'confirmed', rep_confirmed_at = now(),
             confirmed_total_paise = order_total_paise(id), confirmed_lines_hash = order_lines_hash(id)
           WHERE id = %s$q$, v_a));
  PERFORM pg_temp.expect_refused('owner points the order at its still-pending request',
    format($q$UPDATE orders SET status = 'confirmed', rep_confirmed_at = now(),
             confirmed_total_paise = order_total_paise(id), confirmed_lines_hash = order_lines_hash(id),
             confirmation_id = (SELECT id FROM order_confirmations WHERE order_id = %s AND status = 'pending')
           WHERE id = %s$q$, v_a, v_a));
  PERFORM pg_temp.expect_refused('a request cannot be created already used',
    format($q$INSERT INTO order_confirmations (order_id, rep_id, code, total_paise, lines_hash, expires_at, status, used_at, used_channel)
             VALUES (%s, %s, '0000', 1, 'x', now() + interval '1 hour', 'used', now(), 'whatsapp')$q$, v_a, v_deepak));
  PERFORM pg_temp.expect_refused('frozen total of a request cannot be edited',
    format('UPDATE order_confirmations SET total_paise = 1 WHERE order_id = %s AND status = ''pending''', v_a));

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- wrong code, another rep''s code ---';
  PERFORM pg_temp.expect_value('wrong code', pg_temp.confirm(w_deepak, pg_temp.unused_code(v_deepak)), 'wrong_code');
  PERFORM pg_temp.expect_value('wrong code counted against the pending request',
    (SELECT failed_attempts::text FROM order_confirmations WHERE order_id = v_a AND status = 'pending'), '1');

  v_b := create_draft_order(v_ravi, v_ch01, 'whatsapp', 'text', 'confirmation-check');
  PERFORM set_order_line(v_ravi, v_b, p_cet, 4);
  v_code_b := (SELECT confirmation_code FROM present_order_for_confirmation(v_ravi, v_b));
  v_i := 0;
  -- ...and Ravi's code to be one Deepak has never had.
  WHILE (v_code_b = v_code_a1 OR v_code_b IN (SELECT code FROM order_confirmations WHERE rep_id = v_deepak)) AND v_i < 20 LOOP
    v_code_b := (SELECT confirmation_code FROM present_order_for_confirmation(v_ravi, v_b));
    v_i := v_i + 1;
  END LOOP;
  PERFORM pg_temp.expect_value('Deepak sends Ravi''s code', pg_temp.confirm(w_deepak, v_code_b), 'wrong_code');
  PERFORM pg_temp.expect_value('Ravi sends Deepak''s code', pg_temp.confirm(w_ravi, v_code_a1), 'wrong_code');
  PERFORM pg_temp.expect_value('Ravi''s order is untouched',
    (SELECT status FROM orders WHERE id = v_b), 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('Deepak''s order is untouched',
    (SELECT status FROM orders WHERE id = v_a), 'awaiting_confirmation');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- lines changed after the summary was shown ---';
  PERFORM set_order_line(v_deepak, v_a, p_cet, 11);           -- the edit is allowed...
  PERFORM pg_temp.expect_value('...but the old yes no longer fits', pg_temp.confirm(w_deepak, v_code_a1), 'summary_changed');
  PERFORM pg_temp.expect_value('order stays unconfirmed', (SELECT status FROM orders WHERE id = v_a), 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('that request is superseded',
    (SELECT status FROM order_confirmations WHERE order_id = v_a AND code = v_code_a1 ORDER BY id DESC LIMIT 1), 'superseded');

  v_code_a2 := (SELECT confirmation_code FROM present_order_for_confirmation(v_deepak, v_a));
  v_i := 0;
  WHILE v_code_a2 = v_code_a1 AND v_i < 10 LOOP
    v_code_a2 := (SELECT confirmation_code FROM present_order_for_confirmation(v_deepak, v_a));
    v_i := v_i + 1;
  END LOOP;
  PERFORM pg_temp.expect_value('the code from before the edit stays dead', pg_temp.confirm(w_deepak, v_code_a1), 'superseded');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- expired code ---';
  v_c := create_draft_order(v_neha, v_ch14, 'whatsapp', 'text', 'confirmation-check');
  PERFORM set_order_line(v_neha, v_c, p_ors, 3);
  v_code_c := (SELECT confirmation_code FROM present_order_for_confirmation(v_neha, v_c));
  PERFORM set_config('meridian.now', (now() + interval '31 minutes')::text, true);
  PERFORM pg_temp.expect_value('correct sender + correct code, 31 minutes later', pg_temp.confirm(w_neha, v_code_c), 'expired');
  PERFORM set_config('meridian.now', '', true);
  PERFORM pg_temp.expect_value('expired order stays unconfirmed', (SELECT status FROM orders WHERE id = v_c), 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('expired code stays dead after the clock is back', pg_temp.confirm(w_neha, v_code_c), 'expired');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- correct sender + correct code + unchanged order ---';
  SELECT * INTO r FROM confirm_order_by_code('whatsapp', ARRAY[w_deepak], ' ' || v_code_a2 || ' ');
  PERFORM pg_temp.expect_value('Deepak confirms', r.result, 'confirmed');
  SELECT confirmation_id INTO v_conf_a FROM orders WHERE id = v_a;
  PERFORM pg_temp.expect_value('order is confirmed', (SELECT status FROM orders WHERE id = v_a), 'confirmed');
  PERFORM pg_temp.expect_value('order points at the used request',
    (SELECT (c.status = 'used' AND c.code = v_code_a2 AND c.used_channel = 'whatsapp')::text
       FROM order_confirmations c WHERE c.id = v_conf_a), 'true');
  PERFORM pg_temp.expect_value('snapshot = what was frozen when shown',
    (SELECT (o.confirmed_total_paise = c.total_paise AND o.confirmed_lines_hash = c.lines_hash)::text
       FROM orders o JOIN order_confirmations c ON c.id = o.confirmation_id WHERE o.id = v_a), 'true');
  PERFORM pg_temp.expect_value('history actor is the rep',
    (SELECT actor FROM order_status_history WHERE order_id = v_a AND to_status = 'confirmed'), 'user:' || v_deepak);

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- reused code ---';
  PERFORM pg_temp.expect_value('same YES again', pg_temp.confirm(w_deepak, v_code_a2), 'already_used');
  PERFORM pg_temp.expect_value('same YES from the rep''s email', pg_temp.confirm(e_deepak, v_code_a2, 'email'), 'already_used');
  PERFORM pg_temp.expect_value('confirmation unchanged', ((SELECT confirmation_id FROM orders WHERE id = v_a) = v_conf_a)::text, 'true');
  PERFORM pg_temp.expect_refused('a used request cannot be reopened',
    format('UPDATE order_confirmations SET status = ''pending'', used_at = NULL, used_channel = NULL WHERE id = %s', v_conf_a));
  PERFORM pg_temp.expect_refused('lines are locked after confirmation',
    format('SELECT set_order_line(%s, %s, %s, 50)', v_deepak, v_a, p_cet));
  PERFORM pg_temp.expect_refused('cannot present a confirmed order again for a fresh code',
    format('SELECT * FROM present_order_for_confirmation(%s, %s)', v_deepak, v_a));

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- no direct submission bypass ---';
  PERFORM pg_temp.expect_value('submit an order that was shown but never confirmed (never queued)',
    submit_order(v_b, 'MER-ORDER-' || v_b, 'BYPASS-1'), 'not_queued');
  PERFORM pg_temp.expect_refused('borrow another order''s used confirmation',
    format($q$UPDATE orders SET status = 'confirmed', rep_confirmed_at = now(), confirmed_total_paise = c.total_paise,
             confirmed_lines_hash = c.lines_hash, confirmation_id = c.id
           FROM order_confirmations c WHERE c.id = %s AND orders.id = %s$q$, v_conf_a, v_b));
  PERFORM pg_temp.expect_value('Ravi''s order is still unconfirmed', (SELECT status FROM orders WHERE id = v_b), 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('the confirmed order was queued and is submitted with the distributor ref',
    submit_order(v_a, 'MER-ORDER-' || v_a, 'CONF-CHECK-' || v_a), 'submitted');
  PERFORM pg_temp.expect_value('the confirmed order CAN be submitted', (SELECT status FROM orders WHERE id = v_a), 'submitted');
  PERFORM pg_temp.expect_value('ledger charged exactly the confirmed total',
    (SELECT (l.amount_paise = o.confirmed_total_paise)::text FROM orders o
       JOIN credit_ledger l ON l.order_id = o.id AND l.entry_type = 'order_charge' WHERE o.id = v_a), 'true');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- repeated wrong codes lock the rep''s pending request ---';
  -- Ravi already has 1 miss (he sent Deepak's code). 4 more reach the limit of 5.
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp.confirm(w_ravi, pg_temp.unused_code(v_ravi));
  END LOOP;
  PERFORM pg_temp.expect_value('request locked after 5 misses',
    (SELECT status FROM order_confirmations WHERE order_id = v_b AND code = v_code_b ORDER BY id DESC LIMIT 1), 'locked');
  PERFORM pg_temp.expect_value('even the right code is refused now', pg_temp.confirm(w_ravi, v_code_b), 'locked');
  PERFORM pg_temp.expect_value('order still unconfirmed', (SELECT status FROM orders WHERE id = v_b), 'awaiting_confirmation');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- over-credit order still waits for the manager ---';
  v_d := create_draft_order(v_ravi, v_ch03, 'whatsapp', 'text', 'confirmation-check');
  PERFORM set_order_line(v_ravi, v_d, p_mul, 5);
  v_code_d := (SELECT confirmation_code FROM present_order_for_confirmation(v_ravi, v_d));
  SELECT * INTO r FROM confirm_order_by_code('whatsapp', ARRAY[w_ravi], v_code_d);
  PERFORM pg_temp.expect_value('rep''s yes routes it to the manager', r.result, 'awaiting_credit_approval');
  PERFORM pg_temp.expect_value('an approval request was raised for this total',
    (SELECT (a.status = 'pending' AND a.order_total_paise = r.total_paise AND a.token = r.approval_token)::text
       FROM credit_approvals a WHERE a.order_id = v_d), 'true');
  PERFORM pg_temp.expect_value('submit it without the manager (never queued)',
    submit_order(v_d, 'MER-ORDER-' || v_d, 'BYPASS-2'), 'not_queued');
  PERFORM pg_temp.expect_refused('owner marks it confirmed without the manager',
    format('UPDATE orders SET status = ''confirmed'' WHERE id = %s', v_d));
  PERFORM pg_temp.expect_value('still waiting for the manager', (SELECT status FROM orders WHERE id = v_d), 'awaiting_credit_approval');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- identity comes from the sender, not a parameter ---';
  PERFORM pg_temp.expect_value('unknown number', pg_temp.confirm('+919999977777', v_code_b), 'unknown_sender');
  PERFORM pg_temp.expect_value('Imran''s retired number',
    pg_temp.confirm((SELECT uc.value FROM user_contacts uc JOIN users u ON u.id = uc.user_id
                      WHERE u.employee_code = 'REP-NDL-02' AND uc.channel = 'whatsapp' AND uc.valid_to IS NOT NULL), '1234'),
    'unknown_sender');
  PERFORM pg_temp.expect_value('a manager', pg_temp.confirm(pg_temp.contact('ASM-NDL', 'whatsapp'), '1234'), 'not_a_rep');
  PERFORM pg_temp.expect_value('contacts of two different people',
    (SELECT result FROM confirm_order_by_code('whatsapp', ARRAY[w_ravi, w_deepak], '1234')), 'ambiguous_sender');
  PERFORM pg_temp.expect_value('a spoken "haan" transcribed without a code', pg_temp.confirm(w_ravi, 'haan'), 'invalid_code');
  PERFORM pg_temp.expect_refused('unsupported channel',
    format('SELECT * FROM confirm_order_by_code(''web'', ARRAY[%L], ''1234'')', w_ravi));
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'confirmation checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% confirmation check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
