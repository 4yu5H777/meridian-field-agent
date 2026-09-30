-- =============================================================================
-- Distributor callbacks: recorded once, applied only when they move the order
-- forward, unknown orders / statuses change nothing, the rep is told exactly
-- once per real change.
--   node --env-file=.env.owner scripts/db.mjs db/checks-callbacks.sql
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

-- A submitted order for Deepak at Singh Medical (CH-10), returning its id.
CREATE FUNCTION pg_temp.submitted(p_qty int, p_ref text) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE e text; j jsonb; v bigint;
BEGIN
  SELECT uc.value INTO e FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = 'REP-NOI-01' AND uc.channel = 'email' AND uc.valid_to IS NULL ORDER BY uc.id LIMIT 1;
  j := meridian.prepare_order('email', ARRAY[e], (SELECT id FROM meridian.chemists WHERE code = 'CH-10'),
         jsonb_build_array(jsonb_build_object('product_id', (SELECT id FROM meridian.products WHERE sku = 'CET-10-10'), 'qty', p_qty)));
  PERFORM meridian.confirm_order_by_code('email', ARRAY[e], j->'summary'->'confirmation'->>'code');
  v := (j->>'order_id')::bigint;
  IF meridian.submit_order(v, 'MER-ORDER-' || v, p_ref) <> 'submitted' THEN RAISE EXCEPTION 'setup: submit failed'; END IF;
  RETURN v;
END $$;

CREATE FUNCTION pg_temp.notes(p_order bigint) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(payload->>'status', ',' ORDER BY id), '')
    FROM meridian.notification_outbox WHERE kind = 'order_status_to_rep' AND (payload->>'order_id')::bigint = p_order
$$;

DO $t$
DECLARE
  v_a bigint; v_b bigint;
  v_deepak bigint := (SELECT id FROM users WHERE employee_code = 'REP-NOI-01');
  n notification_outbox;
BEGIN
  RAISE NOTICE 'connected as %', session_user;
  PERFORM pg_temp.expect_value('seed callback notifications are never delivered',
    (SELECT count(*)::text FROM notification_outbox WHERE kind = 'order_status_to_rep' AND status IN ('pending', 'sending')), '0');

  v_a := pg_temp.submitted(10, 'MD-100001');

  RAISE NOTICE '--- accepted, then dispatched: applied, rep told each time ---';
  PERFORM pg_temp.expect_value('ACCEPTED applied', record_distributor_event('EVT-A1', 'MD-100001', 'ACCEPTED', now(), '{"status":"ACCEPTED"}'), 'applied');
  PERFORM pg_temp.expect_value('order accepted', (SELECT status FROM orders WHERE id = v_a), 'accepted');
  PERFORM pg_temp.expect_value('rep notification queued', pg_temp.notes(v_a), 'accepted');
  SELECT * INTO n FROM notification_outbox WHERE kind = 'order_status_to_rep' AND (payload->>'order_id')::bigint = v_a;
  PERFORM pg_temp.expect_value('to the rep, on WhatsApp, with the distributor ref',
    n.recipient_user_id || '/' || n.channel || '/' || (n.payload->>'distributor_ref'), v_deepak || '/whatsapp/MD-100001');

  RAISE NOTICE '--- the same callback again ---';
  PERFORM pg_temp.expect_value('duplicate', record_distributor_event('EVT-A1', 'MD-100001', 'ACCEPTED', now(), '{"status":"ACCEPTED"}'), 'duplicate');
  PERFORM pg_temp.expect_value('counted, not stored twice', (SELECT times_received || '/' || count(*) OVER () FROM distributor_events WHERE distributor_event_id = 'EVT-A1'), '2/1');
  PERFORM pg_temp.expect_value('rep not told twice', pg_temp.notes(v_a), 'accepted');

  PERFORM pg_temp.expect_value('a new event with the order''s current status', record_distributor_event('EVT-A2', 'MD-100001', 'accepted', now(), '{}'), 'no_change');
  PERFORM pg_temp.expect_value('DISPATCHED applied', record_distributor_event('EVT-D1', 'MD-100001', 'Dispatched', now(), '{}'), 'applied');
  PERFORM pg_temp.expect_value('rep told of dispatch', pg_temp.notes(v_a), 'accepted,dispatched');

  RAISE NOTICE '--- out of order, unknown order, unknown status, invalid transition ---';
  PERFORM pg_temp.expect_value('a late ACCEPTED after DISPATCHED', record_distributor_event('EVT-A3', 'MD-100001', 'ACCEPTED', now(), '{}'), 'ignored_out_of_order');
  PERFORM pg_temp.expect_value('REJECTED after DISPATCHED', record_distributor_event('EVT-R0', 'MD-100001', 'REJECTED', now(), '{}'), 'ignored_out_of_order');
  PERFORM pg_temp.expect_value('order still dispatched, no new notification', (SELECT status FROM orders WHERE id = v_a) || ' ' || pg_temp.notes(v_a), 'dispatched accepted,dispatched');
  PERFORM pg_temp.expect_value('an order we never sent', record_distributor_event('EVT-X1', 'MD-999999', 'DISPATCHED', now(), '{}'), 'unknown_order');
  PERFORM pg_temp.expect_value('stored for audit, linked to nothing', (SELECT coalesce(order_id::text, 'none') FROM distributor_events WHERE distributor_event_id = 'EVT-X1'), 'none');
  PERFORM pg_temp.expect_value('a status nobody told us about', record_distributor_event('EVT-H1', 'MD-100001', 'ON_HOLD', now(), '{}'), 'unknown_status');
  PERFORM pg_temp.expect_value('nothing notified for either', (SELECT count(*)::text FROM notification_outbox WHERE payload->>'distributor_ref' = 'MD-999999'), '0');

  RAISE NOTICE '--- distributor rejects: charge reversed, rep told with the reason ---';
  v_b := pg_temp.submitted(5, 'MD-100002');
  PERFORM pg_temp.expect_value('REJECTED applied', record_distributor_event('EVT-R1', 'MD-100002', 'REJECTED', now(), '{"reason":"out of stock"}'), 'applied');
  PERFORM pg_temp.expect_value('order distributor_rejected', (SELECT status FROM orders WHERE id = v_b), 'distributor_rejected');
  PERFORM pg_temp.expect_value('ledger charge reversed', (SELECT sum(amount_paise)::text FROM credit_ledger WHERE order_id = v_b), '0');
  PERFORM pg_temp.expect_value('rep told with the reason',
    (SELECT (payload->>'status') || ': ' || (payload->>'reason') FROM notification_outbox WHERE kind = 'order_status_to_rep' AND (payload->>'order_id')::bigint = v_b),
    'distributor_rejected: out of stock');
  PERFORM pg_temp.expect_value('a DISPATCHED after the rejection changes nothing',
    record_distributor_event('EVT-D2', 'MD-100002', 'DISPATCHED', now(), '{}'), 'ignored_out_of_order');

  RAISE NOTICE '--- delivery marks the event as notified ---';
  SELECT * INTO n FROM notification_outbox WHERE kind = 'order_status_to_rep' AND (payload->>'order_id')::bigint = v_b;
  PERFORM 1 FROM claim_notifications(50, 120);
  PERFORM pg_temp.expect_value('sent', complete_notification(n.id, 'wa-delivery-1')::text, 'true');
  PERFORM pg_temp.expect_value('event rep_notified_at set',
    (SELECT (rep_notified_at IS NOT NULL)::text FROM distributor_events WHERE distributor_event_id = 'EVT-R1'), 'true');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'callback checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% callback check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
