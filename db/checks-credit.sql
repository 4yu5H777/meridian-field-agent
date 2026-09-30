-- =============================================================================
-- Credit approval end to end: request raised at confirmation, email queued to
-- the manager on record, manager reply decides exactly that order, rep told.
-- Plus the notification outbox (claim / lease / complete / retry / dead).
--   node --env-file=.env.owner scripts/db.mjs db/checks-credit.sql
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

CREATE FUNCTION pg_temp.contact(p_emp text, p_channel text) RETURNS text
LANGUAGE sql AS $$
  SELECT uc.value FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = p_emp AND uc.channel = p_channel AND uc.valid_to IS NULL ORDER BY uc.valid_from DESC, uc.id DESC LIMIT 1   -- the one notifications use
$$;

-- An over-limit order at Om Sai Medicos (CH-12) for Deepak, confirmed by code.
CREATE FUNCTION pg_temp.over_limit_order(p_qty int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE j jsonb; r record;
BEGIN
  j := meridian.prepare_order('email', ARRAY[pg_temp.contact('REP-NOI-01', 'email')],
         (SELECT id FROM meridian.chemists WHERE code = 'CH-12'),
         jsonb_build_array(jsonb_build_object('product_id', (SELECT id FROM meridian.products WHERE sku = 'MUL-15'), 'qty', p_qty)));
  SELECT * INTO r FROM meridian.confirm_order_by_code('email', ARRAY[pg_temp.contact('REP-NOI-01', 'email')], j->'summary'->'confirmation'->>'code');
  IF r.result <> 'awaiting_credit_approval' THEN RAISE EXCEPTION 'expected awaiting_credit_approval, got %', r.result; END IF;
  RETURN (j->>'order_id')::bigint;
END $$;

DO $t$
DECLARE
  e_kavita  text := pg_temp.contact('ASM-NOI', 'email');      -- Deepak's area manager
  e_pooja   text := pg_temp.contact('ASM-SDL', 'email');      -- another area manager
  e_vikram  text := pg_temp.contact('ASM-NDL', 'email');
  e_deepak  text := pg_temp.contact('REP-NOI-01', 'email');
  w_deepak  text := pg_temp.contact('REP-NOI-01', 'whatsapp');
  v_kavita  bigint := (SELECT id FROM users WHERE employee_code = 'ASM-NOI');
  v_deepak  bigint := (SELECT id FROM users WHERE employee_code = 'REP-NOI-01');
  v_a bigint; v_b bigint; v_c bigint;
  a credit_approvals;
  n notification_outbox;
  r record;
  v_old_token text;
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  RAISE NOTICE '--- the seed''s historical notifications are never delivered ---';
  PERFORM pg_temp.expect_value('nothing from the seed is pending', (SELECT count(*)::text FROM notification_outbox WHERE status IN ('pending', 'sending')), '0');
  PERFORM pg_temp.expect_value('seed notifications are suppressed, not sent',
    (SELECT (count(*) > 0 AND bool_and(status = 'suppressed'))::text FROM notification_outbox), 'true');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- over limit at confirmation: request raised, email queued to the manager on record ---';
  v_a := pg_temp.over_limit_order(300);
  SELECT * INTO a FROM credit_approvals WHERE order_id = v_a;
  PERFORM pg_temp.expect_value('approval request is for Deepak''s manager', a.manager_id::text, v_kavita::text);
  PERFORM pg_temp.expect_value('credit was recomputed at confirmation (owed + total > limit)',
    (a.owed_paise_at_request + a.order_total_paise > a.limit_paise_at_request)::text, 'true');
  SELECT * INTO n FROM notification_outbox WHERE dedupe_key = 'credit_request:' || a.id;
  PERFORM pg_temp.expect_value('one approval email queued', (SELECT count(*)::text FROM notification_outbox WHERE payload->>'approval_id' = a.id::text AND kind = 'credit_approval_request'), '1');
  PERFORM pg_temp.expect_value('to the manager, by email', n.recipient_user_id || '/' || n.channel, v_kavita || '/email');
  PERFORM pg_temp.expect_value('email carries the token and database figures',
    ((n.payload->>'token') = a.token AND (n.payload->>'order_total_paise')::bigint = a.order_total_paise
     AND (n.payload->>'over_by_paise')::bigint = a.owed_paise_at_request + a.order_total_paise - a.limit_paise_at_request
     AND jsonb_array_length(n.payload->'lines') = 1)::text, 'true');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- dispatcher: claim, lease, complete ---';
  SELECT * INTO r FROM claim_notifications(10, 120) WHERE id = n.id;
  PERFORM pg_temp.expect_value('claim resolves the manager''s CURRENT email now', r.address, e_kavita);
  PERFORM pg_temp.expect_value('claimed row is leased', (SELECT status FROM notification_outbox WHERE id = n.id), 'sending');
  PERFORM pg_temp.expect_value('a leased row is not claimed twice', (SELECT count(*)::text FROM claim_notifications(10, 120) WHERE id = n.id), '0');
  PERFORM pg_temp.expect_value('complete', complete_notification(n.id, '<msg-approval-1@lua>')::text, 'true');
  PERFORM pg_temp.expect_value('provider message id recorded on the request for thread matching',
    (SELECT email_message_id FROM credit_approvals WHERE id = a.id), '<msg-approval-1@lua>');
  PERFORM pg_temp.expect_value('completing twice changes nothing', complete_notification(n.id, 'x')::text, 'false');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- replies that must NOT approve ---';
  PERFORM pg_temp.expect_value('malformed token', decide_credit_by_reply(ARRAY[e_kavita], 'CR-XYZ', 'approved'), 'bad_token');
  PERFORM pg_temp.expect_value('unknown decision word', decide_credit_by_reply(ARRAY[e_kavita], a.token, 'maybe'), 'bad_decision');
  PERFORM pg_temp.expect_value('forwarded to another manager who replies', decide_credit_by_reply(ARRAY[e_pooja], a.token, 'approved', 'ok from Pooja'), 'not_authorized');
  PERFORM pg_temp.expect_value('the rep approving his own order', decide_credit_by_reply(ARRAY[e_deepak], a.token, 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('an unknown address', decide_credit_by_reply(ARRAY['boss@gmail.com'], a.token, 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('a profile carrying the manager''s AND a colleague''s address',
    decide_credit_by_reply(ARRAY[e_kavita, e_pooja], a.token, 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('a well-formed token that does not exist', decide_credit_by_reply(ARRAY[e_kavita], 'CR-00000000', 'approved'), 'not_found');
  SELECT a2.token INTO v_old_token FROM credit_approvals a2 JOIN users m ON m.id = a2.manager_id
   WHERE m.employee_code = 'ASM-NDL' AND a2.status IN ('approved', 'rejected') ORDER BY a2.requested_at LIMIT 1;
  PERFORM pg_temp.expect_value('Vikram replies to yesterday''s (already decided) thread', decide_credit_by_reply(ARRAY[e_vikram], v_old_token, 'approved'), 'already_decided');
  PERFORM pg_temp.expect_value('Kavita using Vikram''s old token', decide_credit_by_reply(ARRAY[e_kavita], v_old_token, 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('order still waiting for the manager', (SELECT status FROM orders WHERE id = v_a), 'awaiting_credit_approval');
  PERFORM pg_temp.expect_value('no decision was sent to the rep', (SELECT count(*)::text FROM notification_outbox WHERE kind = 'credit_decision_to_rep' AND payload->>'approval_id' = a.id::text), '0');
  PERFORM pg_temp.expect_value('the four refusals on this request are audited', (SELECT count(*)::text FROM audit_log WHERE action = 'credit.decision_refused' AND entity_id = a.id::text), '4');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- the manager on record approves: that order, and only it, moves on ---';
  v_b := pg_temp.over_limit_order(250);                   -- a second over-limit order, same chemist, own request
  PERFORM pg_temp.expect_value('Kavita approves order A ("ok", three hours later, mixed-case address)',
    decide_credit_by_reply(ARRAY['  ' || upper(e_kavita)], a.token, 'approved', 'ok'), 'approved');
  PERFORM pg_temp.expect_value('order A is confirmed', (SELECT status FROM orders WHERE id = v_a), 'confirmed');
  PERFORM pg_temp.expect_value('history: Kavita moved it', (SELECT actor FROM order_status_history WHERE order_id = v_a AND to_status = 'confirmed'), 'user:' || v_kavita);
  PERFORM pg_temp.expect_value('order B still waits for its own approval', (SELECT status FROM orders WHERE id = v_b), 'awaiting_credit_approval');
  PERFORM pg_temp.expect_guard('A''s approval does not carry B through', format('UPDATE orders SET status = ''confirmed'' WHERE id = %s', v_b));
  SELECT * INTO n FROM notification_outbox WHERE dedupe_key = 'credit_decision:' || a.id;
  PERFORM pg_temp.expect_value('rep told on WhatsApp', n.recipient_user_id || '/' || n.channel || '/' || (n.payload->>'decision'), v_deepak || '/whatsapp/approved');
  PERFORM pg_temp.expect_value('second reply to the same thread', decide_credit_by_reply(ARRAY[e_kavita], a.token, 'rejected'), 'already_decided');
  PERFORM pg_temp.expect_value('rep is told once', (SELECT count(*)::text FROM notification_outbox WHERE kind = 'credit_decision_to_rep' AND payload->>'approval_id' = a.id::text), '1');
  PERFORM pg_temp.expect_value('approved order is queued, passes the credit guard at submission',
    submit_order(v_a, 'MER-ORDER-' || v_a, 'CR-CHECK-A'), 'submitted');
  PERFORM pg_temp.expect_value('A submitted', (SELECT status FROM orders WHERE id = v_a), 'submitted');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- rejection ---';
  PERFORM pg_temp.expect_value('Kavita rejects B', decide_credit_by_reply(ARRAY[e_kavita], (SELECT token FROM credit_approvals WHERE order_id = v_b), 'rejected', 'No. Collect payment first.'), 'rejected');
  PERFORM pg_temp.expect_value('B is credit_rejected', (SELECT status FROM orders WHERE id = v_b), 'credit_rejected');
  PERFORM pg_temp.expect_value('rep told of the rejection with the manager''s note',
    (SELECT (payload->>'decision') || ': ' || (payload->>'note') FROM notification_outbox WHERE dedupe_key = 'credit_decision:' || (SELECT id FROM credit_approvals WHERE order_id = v_b)),
    'rejected: No. Collect payment first.');
  PERFORM pg_temp.expect_value('a rejected order cannot be submitted (never queued)', submit_order(v_b, 'MER-ORDER-' || v_b, 'XREF'), 'not_queued');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- late reply after the rep cancelled ---';
  v_c := pg_temp.over_limit_order(200);
  PERFORM cancel_order(v_deepak, v_c);
  PERFORM pg_temp.expect_value('manager approves a cancelled order', decide_credit_by_reply(ARRAY[e_kavita], (SELECT token FROM credit_approvals WHERE order_id = v_c), 'approved'), 'already_decided');
  PERFORM pg_temp.expect_value('its request is superseded', (SELECT status FROM credit_approvals WHERE order_id = v_c), 'superseded');
  PERFORM pg_temp.expect_value('order stays cancelled', (SELECT status FROM orders WHERE id = v_c), 'cancelled');
  PERFORM pg_temp.expect_value('no decision sent for it', (SELECT count(*)::text FROM notification_outbox WHERE kind = 'credit_decision_to_rep' AND payload->>'order_id' = v_c::text), '0');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- dispatcher: retries, lease expiry, dead letter, retired contact ---';
  SELECT * INTO n FROM notification_outbox WHERE dedupe_key = 'credit_decision:' || a.id;
  SELECT * INTO r FROM claim_notifications(50, 120) WHERE id = n.id;
  PERFORM pg_temp.expect_value('rep notification goes to his current WhatsApp', r.channel || ' ' || r.address, 'whatsapp ' || w_deepak);
  PERFORM pg_temp.expect_value('send failed -> retry later', fail_notification(n.id, 'provider timeout'), 'pending');
  PERFORM pg_temp.expect_value('not due yet', (SELECT count(*)::text FROM claim_notifications(50, 120) WHERE id = n.id), '0');
  PERFORM set_config('meridian.now', (now() + interval '2 minutes')::text, true);
  PERFORM pg_temp.expect_value('due after the backoff', (SELECT attempts::text FROM claim_notifications(50, 120) WHERE id = n.id), '2');
  PERFORM set_config('meridian.now', (now() + interval '10 minutes')::text, true);
  PERFORM pg_temp.expect_value('a crashed sender''s lease expires and the row is claimed again',
    (SELECT attempts::text FROM claim_notifications(50, 120) WHERE id = n.id), '3');
  FOR i IN 4..6 LOOP
    PERFORM fail_notification(n.id, 'still failing');
    PERFORM set_config('meridian.now', (now() + make_interval(hours => i))::text, true);
    PERFORM 1 FROM claim_notifications(50, 120) WHERE id = n.id;
  END LOOP;
  PERFORM pg_temp.expect_value('gives up after 6 attempts', fail_notification(n.id, 'still failing'), 'dead');
  PERFORM set_config('meridian.now', '', true);
  -- The WhatsApp number is retired before sending: the email is used instead.
  SELECT * INTO n FROM notification_outbox WHERE dedupe_key = 'credit_decision:' || (SELECT id FROM credit_approvals WHERE order_id = v_b);
  UPDATE user_contacts SET valid_to = valid_from + interval '1 second'
   WHERE user_id = v_deepak AND channel = 'whatsapp' AND valid_to IS NULL;
  PERFORM set_config('meridian.now', (now() + interval '1 day')::text, true);   -- past any lease from the claims above
  PERFORM pg_temp.expect_value('retired WhatsApp -> falls back to email', (SELECT channel || ' ' || address FROM claim_notifications(50, 120) WHERE id = n.id), 'email ' || e_deepak);
  PERFORM set_config('meridian.now', '', true);

  RAISE NOTICE '--- tables the dispatcher owns cannot be erased ---';
  PERFORM pg_temp.expect_guard('delete an outbox row', 'DELETE FROM notification_outbox');
  PERFORM pg_temp.expect_guard('truncate the outbox (as owner)', 'TRUNCATE notification_outbox');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'credit checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% credit check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
