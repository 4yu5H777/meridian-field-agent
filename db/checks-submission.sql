-- =============================================================================
-- Submission to the distributor: queue on confirmation, claim, idempotent
-- submit, guard at the authoritative moment, retries.
--   node --env-file=.env.owner scripts/db.mjs db/checks-submission.sql
-- Owner login, one transaction, BEGIN ... ROLLBACK. Non-zero exit on failure.
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

CREATE FUNCTION pg_temp.expect_guard(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_ok boolean;
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL  %: statement was allowed', p_name;
    v_ok := false;
  EXCEPTION WHEN others THEN
    v_ok := SQLERRM LIKE 'GUARD:%';
    IF v_ok THEN RAISE NOTICE 'PASS  %  ->  %', p_name, SQLERRM;
    ELSE RAISE NOTICE 'FAIL  %: unexpected error [%] %', p_name, SQLSTATE, SQLERRM; END IF;
  END;
  INSERT INTO check_results VALUES (p_name, v_ok);
END $$;

-- Prepare + confirm an order for Deepak at a chemist, returning the order id and its status.
CREATE FUNCTION pg_temp.confirmed(p_chem text, p_items jsonb) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE e text; j jsonb; r record;
BEGIN
  SELECT uc.value INTO e FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = 'REP-NOI-01' AND uc.channel = 'email' AND uc.valid_to IS NULL ORDER BY uc.id LIMIT 1;
  j := meridian.prepare_order('email', ARRAY[e], (SELECT id FROM meridian.chemists WHERE code = p_chem), p_items);
  SELECT * INTO r FROM meridian.confirm_order_by_code('email', ARRAY[e], j->'summary'->'confirmation'->>'code');
  RETURN (j->>'order_id')::bigint;
END $$;

CREATE FUNCTION pg_temp.items(p_sku text, p_qty int) RETURNS jsonb
LANGUAGE sql AS $$ SELECT jsonb_build_array(jsonb_build_object('product_id', (SELECT id FROM meridian.products WHERE sku = p_sku), 'qty', p_qty)) $$;

DO $t$
DECLARE
  v_ok bigint; v_o1 bigint; v_o2 bigint; v_draft bigint; v_over bigint;
  r record;
  v_ledger_before bigint;
  v_deepak bigint := (SELECT id FROM users WHERE employee_code = 'REP-NOI-01');
BEGIN
  RAISE NOTICE 'connected as %', session_user;
  PERFORM pg_temp.expect_value('the seed queues nothing for sending', (SELECT count(*)::text FROM distributor_submissions WHERE status IN ('pending', 'sending')), '0');
  PERFORM pg_temp.expect_value('seed history submissions are closed', (SELECT (count(*) > 0 AND bool_and(status IN ('submitted', 'suppressed', 'cancelled')))::text FROM distributor_submissions), 'true');
  PERFORM pg_temp.expect_value('the placeholder function is gone', (SELECT count(*)::text FROM pg_proc WHERE proname = 'mark_order_submitted'), '0');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- confirmed within the limit -> queued -> claimed -> submitted ---';
  v_ok := pg_temp.confirmed('CH-10', pg_temp.items('CET-10-10', 10));
  PERFORM pg_temp.expect_value('order confirmed', (SELECT status FROM orders WHERE id = v_ok), 'confirmed');
  PERFORM pg_temp.expect_value('queued with its idempotency key', (SELECT status || ' ' || idempotency_key FROM distributor_submissions WHERE order_id = v_ok), 'pending MER-ORDER-' || v_ok);
  SELECT * INTO r FROM claim_submissions(50, 120) WHERE order_id = v_ok;
  PERFORM pg_temp.expect_value('claim carries the key, SKUs, quantities and confirmed total',
    (r.idempotency_key = 'MER-ORDER-' || v_ok AND r.payload->>'order_ref' = r.idempotency_key
     AND r.payload->'lines'->0->>'sku' = 'CET-10-10' AND (r.payload->'lines'->0->>'qty')::int = 10
     AND (r.payload->>'total_paise')::bigint = (SELECT confirmed_total_paise FROM orders WHERE id = v_ok))::text, 'true');
  PERFORM pg_temp.expect_value('claimed row is leased', (SELECT count(*)::text FROM claim_submissions(50, 120) WHERE order_id = v_ok), '0');
  SELECT coalesce(sum(amount_paise), 0) INTO v_ledger_before FROM credit_ledger WHERE order_id = v_ok;
  PERFORM pg_temp.expect_value('wrong idempotency key', submit_order(v_ok, 'MER-ORDER-999999', 'MD-000001'), 'key_mismatch');
  PERFORM pg_temp.expect_value('malformed distributor ref', submit_order(v_ok, 'MER-ORDER-' || v_ok, 'x; DROP'), 'bad_ref');
  PERFORM pg_temp.expect_value('submit', submit_order(v_ok, 'MER-ORDER-' || v_ok, 'MD-000001'), 'submitted');
  PERFORM pg_temp.expect_value('order is submitted with the distributor ref', (SELECT status || ' ' || distributor_ref FROM orders WHERE id = v_ok), 'submitted MD-000001');
  PERFORM pg_temp.expect_value('queue row closed', (SELECT status || ' ' || distributor_ref FROM distributor_submissions WHERE order_id = v_ok), 'submitted MD-000001');
  PERFORM pg_temp.expect_value('history: the submitter service moved it', (SELECT actor FROM order_status_history WHERE order_id = v_ok AND to_status = 'submitted'), 'service:distributor-submitter');
  PERFORM pg_temp.expect_value('ledger charged the confirmed total once',
    (SELECT (count(*) = 1 AND sum(amount_paise) = (SELECT confirmed_total_paise FROM orders WHERE id = v_ok))::text FROM credit_ledger WHERE order_id = v_ok AND entry_type = 'order_charge'), 'true');
  PERFORM pg_temp.expect_value('audited', (SELECT count(*)::text FROM audit_log WHERE action = 'order.submitted' AND entity_id = v_ok::text), '1');

  RAISE NOTICE '--- idempotent ---';
  PERFORM pg_temp.expect_value('same key, same ref again (a retry after a lost response)', submit_order(v_ok, 'MER-ORDER-' || v_ok, 'MD-000001'), 'already_submitted');
  PERFORM pg_temp.expect_value('a different ref for the same order', submit_order(v_ok, 'MER-ORDER-' || v_ok, 'MD-000999'), 'conflict');
  PERFORM pg_temp.expect_value('still one charge, same ref',
    (SELECT count(*)::text || ' ' || (SELECT distributor_ref FROM orders WHERE id = v_ok) FROM credit_ledger WHERE order_id = v_ok AND entry_type = 'order_charge'), '1 MD-000001');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- unconfirmed orders cannot be submitted by any path ---';
  v_draft := create_draft_order(v_deepak, (SELECT id FROM chemists WHERE code = 'CH-11'), 'email', 'text');
  PERFORM set_order_line(v_deepak, v_draft, (SELECT id FROM products WHERE sku = 'CET-10-10'), 2);
  PERFORM pg_temp.expect_value('a draft is never queued', submit_order(v_draft, 'MER-ORDER-' || v_draft, 'MD-000002'), 'not_queued');
  INSERT INTO distributor_submissions (order_id, idempotency_key) VALUES (v_draft, 'MER-ORDER-' || v_draft);   -- owner forges a queue row
  PERFORM pg_temp.expect_value('a forged queue row for a draft still cannot submit', submit_order(v_draft, 'MER-ORDER-' || v_draft, 'MD-000002'), 'not_confirmed');
  PERFORM pg_temp.expect_value('the claim drops it instead of sending it', (SELECT count(*)::text FROM claim_submissions(50, 120) WHERE order_id = v_draft), '0');
  PERFORM pg_temp.expect_value('its queue row is cancelled', (SELECT status FROM distributor_submissions WHERE order_id = v_draft), 'cancelled');
  PERFORM pg_temp.expect_guard('owner cannot jump a draft to submitted', format($q$UPDATE orders SET status = 'submitted', distributor_ref = 'MD-X' WHERE id = %s$q$, v_draft));

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- over the limit: nothing is queued until the manager approves ---';
  v_over := pg_temp.confirmed('CH-12', pg_temp.items('MUL-15', 300));
  PERFORM pg_temp.expect_value('waiting for approval, not queued', (SELECT o.status || ' / ' || coalesce(d.status, 'not queued') FROM orders o LEFT JOIN distributor_submissions d ON d.order_id = o.id WHERE o.id = v_over),
    'awaiting_credit_approval / not queued');
  PERFORM pg_temp.expect_value('submit before approval', submit_order(v_over, 'MER-ORDER-' || v_over, 'MD-000003'), 'not_queued');
  PERFORM decide_credit_by_reply(ARRAY[(SELECT uc.value FROM user_contacts uc JOIN users u ON u.id = uc.user_id WHERE u.employee_code = 'ASM-NOI' AND uc.channel = 'email' AND uc.valid_to IS NULL LIMIT 1)],
                                 (SELECT token FROM credit_approvals WHERE order_id = v_over), 'approved', 'ok');
  PERFORM pg_temp.expect_value('approval queues it', (SELECT status FROM distributor_submissions WHERE order_id = v_over), 'pending');
  PERFORM pg_temp.expect_value('approved order submits (approval covers exactly this total)', submit_order(v_over, 'MER-ORDER-' || v_over, 'MD-000003'), 'submitted');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- credit is re-checked at submission, not taken from the confirmation ---';
  -- Arogya (CH-11): two orders confirmed within the limit; once the first is
  -- submitted (and charged), the second no longer fits and is blocked.
  v_o1 := pg_temp.confirmed('CH-11', pg_temp.items('MUL-15', 150));
  v_o2 := pg_temp.confirmed('CH-11', pg_temp.items('MUL-15', 150));
  PERFORM pg_temp.expect_value('both confirmed within the limit', (SELECT string_agg(status, ',' ORDER BY id) FROM orders WHERE id IN (v_o1, v_o2)), 'confirmed,confirmed');
  PERFORM pg_temp.expect_value('first submits', submit_order(v_o1, 'MER-ORDER-' || v_o1, 'MD-000004'), 'submitted');
  PERFORM pg_temp.expect_value('second is not claimed for sending', (SELECT count(*)::text FROM claim_submissions(50, 120) WHERE order_id = v_o2), '0');
  PERFORM pg_temp.expect_value('it is blocked by the guard, with the reason', (SELECT status || ': ' || (last_error LIKE 'GUARD:%exceeds limit%')::text FROM distributor_submissions WHERE order_id = v_o2), 'blocked: true');
  PERFORM pg_temp.expect_value('submitting it anyway is refused and recorded', submit_order(v_o2, 'MER-ORDER-' || v_o2, 'MD-000005'), 'blocked');
  PERFORM pg_temp.expect_value('it stays confirmed, uncharged', (SELECT o.status || ' / ' || count(l.*) FROM orders o LEFT JOIN credit_ledger l ON l.order_id = o.id WHERE o.id = v_o2 GROUP BY o.status), 'confirmed / 0');
  PERFORM pg_temp.expect_value('a dry run leaves no trace', (SELECT count(*)::text FROM orders WHERE distributor_ref LIKE 'DRY-RUN-%'), '0');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- retries, lease expiry, give up ---';
  v_ok := pg_temp.confirmed('CH-10', pg_temp.items('ORS-LEM-21', 4));
  PERFORM pg_temp.expect_value('claimed', (SELECT attempts::text FROM claim_submissions(50, 120) WHERE order_id = v_ok), '1');
  PERFORM pg_temp.expect_value('distributor unreachable -> retry later', fail_submission(v_ok, 'connect timeout'), 'pending');
  PERFORM pg_temp.expect_value('not due yet', (SELECT count(*)::text FROM claim_submissions(50, 120) WHERE order_id = v_ok), '0');
  PERFORM set_config('meridian.now', (now() + interval '2 minutes')::text, true);
  PERFORM pg_temp.expect_value('due after the backoff', (SELECT attempts::text FROM claim_submissions(50, 120) WHERE order_id = v_ok), '2');
  PERFORM set_config('meridian.now', (now() + interval '10 minutes')::text, true);
  PERFORM pg_temp.expect_value('a crashed submitter''s lease expires', (SELECT attempts::text FROM claim_submissions(50, 120) WHERE order_id = v_ok), '3');
  FOR i IN 4..8 LOOP
    PERFORM fail_submission(v_ok, 'still down');
    PERFORM set_config('meridian.now', (now() + make_interval(hours => i))::text, true);
    PERFORM 1 FROM claim_submissions(50, 120) WHERE order_id = v_ok;
  END LOOP;
  PERFORM pg_temp.expect_value('gives up after 8 attempts', fail_submission(v_ok, 'still down'), 'dead');
  PERFORM set_config('meridian.now', '', true);

  RAISE NOTICE '--- a cancelled confirmed order is never sent ---';
  v_ok := pg_temp.confirmed('CH-10', pg_temp.items('SAN-500', 2));
  PERFORM cancel_order(v_deepak, v_ok);
  PERFORM pg_temp.expect_value('queue row cancelled with the order', (SELECT status FROM distributor_submissions WHERE order_id = v_ok), 'cancelled');
  PERFORM pg_temp.expect_value('submit after cancel', submit_order(v_ok, 'MER-ORDER-' || v_ok, 'MD-000006'), 'not_confirmed');

  PERFORM pg_temp.expect_guard('queue rows cannot be deleted', 'DELETE FROM distributor_submissions');
  PERFORM pg_temp.expect_guard('queue cannot be truncated (as owner)', 'TRUNCATE distributor_submissions');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'submission checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% submission check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
