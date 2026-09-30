-- =============================================================================
-- Order intake (prepare_order) and summary integrity (live_order_summaries,
-- mark_summaries_delivered), end to end.
--   node --env-file=.env.owner scripts/db.mjs db/checks-intake.sql
-- Runs as the owner login so one transaction can also play the confirmation
-- gate (confirm_order_by_code) and move the clock. Which ROLE may call which
-- function is proven in checks-agent.sql / checks-system.sql / checks-readonly.sql.
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
   WHERE u.employee_code = p_emp AND uc.channel = p_channel AND uc.valid_to IS NULL
     AND (uc.note IS NULL OR uc.note NOT LIKE 'TEST ONLY:%')
   ORDER BY uc.id LIMIT 1
$$;

-- prepare_order for one sender, lines given as '[{"product_id":..,"qty":..}]' built from SKUs.
CREATE FUNCTION pg_temp.lines(p_items text[]) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_agg(jsonb_build_object('product_id', p.id, 'qty', split_part(i.item, ':', 2)::numeric,
                                      'raw_text', 'check ' || split_part(i.item, ':', 1)) ORDER BY i.n)
    FROM unnest(p_items) WITH ORDINALITY AS i(item, n)
    JOIN meridian.products p ON p.sku = split_part(i.item, ':', 1)
$$;

DO $t$
DECLARE
  e_deepak  text   := pg_temp.contact('REP-NOI-01', 'email');
  e_ravi    text   := pg_temp.contact('REP-NDL-01', 'email');
  e_mgr     text   := pg_temp.contact('ASM-NOI', 'email');
  v_deepak  bigint := (SELECT id FROM users WHERE employee_code = 'REP-NOI-01');
  v_ch10    bigint := (SELECT id FROM chemists WHERE code = 'CH-10');
  v_ch12    bigint := (SELECT id FROM chemists WHERE code = 'CH-12');
  v_ch01    bigint := (SELECT id FROM chemists WHERE code = 'CH-01');
  v_ch10_on_route_today boolean := EXISTS (SELECT 1 FROM route_stops WHERE rep_id = v_deepak AND chemist_id = v_ch10
                                             AND weekday = extract(isodow FROM ist_date(now())));
  v_orders_before bigint;
  j1 jsonb; j2 jsonb; j3 jsonb; j4 jsonb; jo jsonb;
  s  jsonb;
  r  record;
  v_code_1 text; v_code_2 text;
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- identify_sender ---';
  PERFORM pg_temp.expect_value('Deepak''s seeded email is a rep',
    (SELECT result || '/' || role FROM identify_sender('email', ARRAY[e_deepak])), 'ok/rep');
  PERFORM pg_temp.expect_value('messy formatting still resolves',
    (SELECT result FROM identify_sender('email', ARRAY['  ' || upper(e_deepak) || ' '])), 'ok');
  PERFORM pg_temp.expect_value('a manager resolves, as a manager',
    (SELECT result || '/' || role FROM identify_sender('email', ARRAY[e_mgr])), 'ok/area_manager');
  PERFORM pg_temp.expect_value('unknown contact', (SELECT result FROM identify_sender('email', ARRAY['nobody@example.com'])), 'unknown_sender');
  PERFORM pg_temp.expect_value('two people', (SELECT result FROM identify_sender('email', ARRAY[e_deepak, e_ravi])), 'ambiguous_sender');
  PERFORM pg_temp.expect_value('no contacts', (SELECT result FROM identify_sender('email', '{}')), 'unknown_sender');
  PERFORM pg_temp.expect_value('channel must be whatsapp or email', (SELECT result FROM identify_sender('web', ARRAY[e_deepak])), 'bad_channel');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- normal order: prices, schemes, off-route, code ---';
  j1 := prepare_order('email', ARRAY[e_deepak], v_ch10, pg_temp.lines(ARRAY['CET-10-10:10', 'ORS-ORG-21:6']), 'text', 'check-intake-1');
  s := j1->'summary';
  PERFORM pg_temp.expect_value('order is waiting for the rep', s->>'status', 'awaiting_confirmation');
  PERFORM pg_temp.expect_value('two lines', jsonb_array_length(s->'lines')::text, '2');
  PERFORM pg_temp.expect_value('Cetimer priced from the list, 5% scheme',
    (SELECT (l->>'unit_price_paise') || ' ' || (l->>'discount_paise') || ' ' || (l->>'line_total_paise') || ' ' || (l->>'scheme')
       FROM jsonb_array_elements(s->'lines') l WHERE l->>'product' = 'Cetimer 10 Tablet'),
    '2000 1000 19000 Cetimer 10: 5% off');
  PERFORM pg_temp.expect_value('ORS Orange buy 2 get 1: 6 bought, 3 free',
    (SELECT (l->>'qty') || '+' || (l->>'free_qty') || ' = ' || (l->>'line_total_paise')
       FROM jsonb_array_elements(s->'lines') l WHERE l->>'product' = 'Meridian ORS Orange'), '6+3 = 13200');
  PERFORM pg_temp.expect_value('total = sum of line totals in the database',
    (s->>'total_paise'), (SELECT order_total_paise((j1->>'order_id')::bigint))::text);
  PERFORM pg_temp.expect_value('total is 322.00', (s->>'total_paise'), '32200');
  PERFORM pg_temp.expect_value('off-route flag follows today''s route', (s->>'is_off_route'), (NOT v_ch10_on_route_today)::text);
  PERFORM pg_temp.expect_value('credit preview: well within limit', (s->'credit'->>'over_limit'), 'false');
  PERFORM pg_temp.expect_value('code is live and frozen at this total',
    ((s->'confirmation'->>'code') ~ '^[0-9]{4}$' AND (s->'confirmation'->>'total_paise') = (s->>'total_paise'))::text, 'true');
  PERFORM pg_temp.expect_value('no duplicate', coalesce(s->>'duplicate', 'none'), 'none');
  v_code_1 := s->'confirmation'->>'code';

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- repeated product lines are merged ---';
  j2 := prepare_order('email', ARRAY[e_deepak], v_ch12, pg_temp.lines(ARRAY['CET-10-10:4', 'ORS-LEM-21:1', 'CET-10-10:6']), 'text', 'check-intake-2');
  PERFORM pg_temp.expect_value('Cetimer 4 + 6 = one line of 10',
    (SELECT string_agg((l->>'product') || ' x' || (l->>'qty'), ', ' ORDER BY (l->>'line_no')::int)
       FROM jsonb_array_elements(j2->'summary'->'lines') l), 'Cetimer 10 Tablet x10, Meridian ORS Lemon x1');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- supersede (D1): the earlier UNCONFIRMED order for the same chemist ---';
  j3 := prepare_order('email', ARRAY[e_deepak], v_ch10, pg_temp.lines(ARRAY['CET-10-10:12', 'ORS-ORG-21:6']), 'text', 'check-intake-3');
  PERFORM pg_temp.expect_value('first order reported as superseded',
    ((j3->'superseded_order_ids') @> to_jsonb(ARRAY[(j1->>'order_id')::bigint]))::text, 'true');
  PERFORM pg_temp.expect_value('first order cancelled', (SELECT status FROM orders WHERE id = (j1->>'order_id')::bigint), 'cancelled');
  PERFORM pg_temp.expect_value('its code is dead',
    (SELECT result FROM confirm_order_by_code('email', ARRAY[e_deepak], v_code_1)), 'superseded');
  PERFORM pg_temp.expect_value('other chemist''s unconfirmed order untouched',
    (SELECT status FROM orders WHERE id = (j2->>'order_id')::bigint), 'awaiting_confirmation');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- confirmed orders are never superseded; the repeat is flagged as a duplicate ---';
  v_code_2 := j3->'summary'->'confirmation'->>'code';
  PERFORM pg_temp.expect_value('rep confirms order 3 with its code',
    (SELECT result FROM confirm_order_by_code('email', ARRAY[e_deepak], v_code_2)), 'confirmed');
  j4 := prepare_order('email', ARRAY[e_deepak], v_ch10, pg_temp.lines(ARRAY['ORS-ORG-21:6', 'CET-10-10:12']), 'text', 'check-intake-4');
  PERFORM pg_temp.expect_value('confirmed order 3 is still confirmed',
    (SELECT status FROM orders WHERE id = (j3->>'order_id')::bigint), 'confirmed');
  PERFORM pg_temp.expect_value('nothing superseded this time', jsonb_array_length(j4->'superseded_order_ids')::text, '0');
  PERFORM pg_temp.expect_value('same chemist + same lines within 10 min = possible duplicate of order 3',
    (j4->'summary'->'duplicate'->>'order_id'), (j3->>'order_id'));

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- over the credit limit: preview now, manager approval after YES ---';
  jo := prepare_order('email', ARRAY[e_deepak], v_ch12, pg_temp.lines(ARRAY['MUL-15:300']), 'text', 'check-intake-credit');
  PERFORM pg_temp.expect_value('j2 (same chemist, unconfirmed) was superseded by this one',
    (SELECT status FROM orders WHERE id = (j2->>'order_id')::bigint), 'cancelled');
  PERFORM pg_temp.expect_value('credit preview says over limit', (jo->'summary'->'credit'->>'over_limit'), 'true');
  PERFORM pg_temp.expect_value('preview names the approving manager', (jo->'summary'->'credit'->>'manager_name'), 'Kavita Srivastava');
  PERFORM pg_temp.expect_value('preview numbers come from the ledger',
    (jo->'summary'->'credit'->>'owed_paise'), (SELECT chemist_owed_paise(v_ch12))::text);
  SELECT * INTO r FROM confirm_order_by_code('email', ARRAY[e_deepak], jo->'summary'->'confirmation'->>'code');
  PERFORM pg_temp.expect_value('rep''s YES routes it to the manager', r.result, 'awaiting_credit_approval');
  PERFORM pg_temp.expect_value('approval request raised for this order and total',
    (SELECT (a.status = 'pending' AND a.order_total_paise = (jo->'summary'->>'total_paise')::bigint)::text
       FROM credit_approvals a WHERE a.order_id = (jo->>'order_id')::bigint), 'true');
  PERFORM pg_temp.expect_value('it cannot be submitted without the manager (never queued)',
    submit_order((jo->>'order_id')::bigint, 'MER-ORDER-' || (jo->>'order_id'), 'BYPASS'), 'not_queued');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- refusals: nothing is created, nothing is superseded ---';
  SELECT count(*) INTO v_orders_before FROM orders;
  PERFORM pg_temp.expect_guard('unknown sender',
    format('SELECT prepare_order(''email'', ARRAY[''nobody@example.com''], %s, %L)', v_ch10, pg_temp.lines(ARRAY['CET-10-10:1'])));
  PERFORM pg_temp.expect_guard('a manager cannot place an order',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_mgr, v_ch10, pg_temp.lines(ARRAY['CET-10-10:1'])));
  PERFORM pg_temp.expect_guard('another rep''s chemist',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch01, pg_temp.lines(ARRAY['CET-10-10:1'])));
  PERFORM pg_temp.expect_guard('no lines', format('SELECT prepare_order(''email'', ARRAY[%L], %s, ''[]'')', e_deepak, v_ch10));
  PERFORM pg_temp.expect_guard('quantity 0', format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch10, pg_temp.lines(ARRAY['CET-10-10:0'])));
  PERFORM pg_temp.expect_guard('fractional quantity', format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch10, pg_temp.lines(ARRAY['CET-10-10:2.5'])));
  PERFORM pg_temp.expect_guard('merged quantity above 100000',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch10, pg_temp.lines(ARRAY['CET-10-10:60000', 'CET-10-10:60000'])));
  PERFORM pg_temp.expect_guard('a product id that does not exist',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, ''[{"product_id": 999999, "qty": 1}]'')', e_deepak, v_ch10));
  PERFORM pg_temp.expect_guard('a line with a price but no product_id (prices are never taken from input)',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, ''[{"qty": 1, "unit_price_paise": 1}]'')', e_deepak, v_ch10));
  PERFORM pg_temp.expect_guard('101 lines (the limit is 100: a big PO runs to 60+)',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch10,
           (SELECT jsonb_agg(jsonb_build_object('product_id', (SELECT id FROM products WHERE sku = 'CET-10-10'), 'qty', 1)) FROM generate_series(1, 101))));
  PERFORM pg_temp.expect_guard('good first line, bad second line: all or nothing',
    format('SELECT prepare_order(''email'', ARRAY[%L], %s, %L)', e_deepak, v_ch10,
           (pg_temp.lines(ARRAY['CET-10-10:5']) || '[{"product_id": 999999, "qty": 1}]'::jsonb)));
  PERFORM pg_temp.expect_value('no order was created by any refusal', (SELECT count(*) FROM orders)::text, v_orders_before::text);
  PERFORM pg_temp.expect_value('the live unconfirmed order was not superseded by the failed attempt',
    (SELECT status FROM orders WHERE id = (j4->>'order_id')::bigint), 'awaiting_confirmation');

  -- ---------------------------------------------------------------------------
  RAISE NOTICE '--- summary integrity: live summaries and delivery ---';
  PERFORM pg_temp.expect_value('Deepak has exactly one live summary (order 4), not yet delivered',
    (SELECT string_agg(order_id || ':' || delivered, ',') FROM live_order_summaries('email', ARRAY[e_deepak])),
    (j4->>'order_id') || ':false');
  PERFORM pg_temp.expect_value('live summary = the summary prepare_order returned',
    ((SELECT summary FROM live_order_summaries('email', ARRAY[e_deepak])) = j4->'summary')::text, 'true');
  PERFORM pg_temp.expect_value('another rep sees none of Deepak''s summaries',
    (SELECT count(*)::text FROM live_order_summaries('email', ARRAY[e_ravi]) WHERE order_id = (j4->>'order_id')::bigint), '0');
  PERFORM pg_temp.expect_value('unknown sender sees nothing',
    (SELECT count(*)::text FROM live_order_summaries('email', ARRAY['nobody@example.com'])), '0');
  PERFORM pg_temp.expect_value('another rep cannot mark Deepak''s summary delivered',
    mark_summaries_delivered('email', ARRAY[e_ravi], ARRAY[(SELECT confirmation_id FROM live_order_summaries('email', ARRAY[e_deepak]))])::text, '0');
  PERFORM pg_temp.expect_value('Deepak''s channel marks it delivered once',
    mark_summaries_delivered('email', ARRAY[e_deepak], ARRAY[(SELECT confirmation_id FROM live_order_summaries('email', ARRAY[e_deepak]))])::text, '1');
  PERFORM pg_temp.expect_value('a second mark changes nothing',
    mark_summaries_delivered('email', ARRAY[e_deepak], ARRAY[(SELECT confirmation_id FROM live_order_summaries('email', ARRAY[e_deepak]))])::text, '0');
  PERFORM pg_temp.expect_value('now listed as delivered',
    (SELECT delivered::text FROM live_order_summaries('email', ARRAY[e_deepak])), 'true');
  PERFORM set_config('meridian.now', (now() + interval '31 minutes')::text, true);
  PERFORM pg_temp.expect_value('expired summaries are not live', (SELECT count(*)::text FROM live_order_summaries('email', ARRAY[e_deepak])), '0');
  PERFORM set_config('meridian.now', '', true);
  PERFORM pg_temp.expect_value('confirmed / cancelled orders are never live',
    (SELECT count(*)::text FROM live_order_summaries('email', ARRAY[e_deepak])
      WHERE order_id IN ((j1->>'order_id')::bigint, (j3->>'order_id')::bigint, (jo->>'order_id')::bigint)), '0');
END $t$;

-- Generic names (migration 20260930): what a rep calls a medicine by its ingredient.
CREATE FUNCTION pg_temp.exact(p_text text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(p.sku, ',' ORDER BY p.sku), 'none')
    FROM meridian.match_product((SELECT id FROM meridian.users WHERE employee_code = 'REP-NOI-01'), p_text) m
    JOIN meridian.products p ON p.id = m.product_id WHERE m.score >= 1 $$;
CREATE FUNCTION pg_temp.top(p_text text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce((SELECT round(m.score::numeric, 2)::text
    FROM meridian.match_product((SELECT id FROM meridian.users WHERE employee_code = 'REP-NOI-01'), p_text) m
   ORDER BY m.score DESC LIMIT 1), '0') $$;
DO $t$
BEGIN
  RAISE NOTICE '--- generic names: one ingredient, several packs -> the rep is asked ---';
  PERFORM pg_temp.expect_value('"paracetamol 650" means both Meridol 650 packs', pg_temp.exact('paracetamol 650'), 'MER-650-10,MER-650-15');
  PERFORM pg_temp.expect_value('... and so do "pcm 650", "para 650" and the Hindi spelling',
    pg_temp.exact('pcm 650') || ' / ' || pg_temp.exact('Para 650') || ' / ' || pg_temp.exact('पैरासिटामोल 650'),
    'MER-650-10,MER-650-15 / MER-650-10,MER-650-15 / MER-650-10,MER-650-15');
  PERFORM pg_temp.expect_value('"paracetamol 500" is one product', pg_temp.exact('paracetamol 500'), 'MER-500-15');
  PERFORM pg_temp.expect_value('"ibuprofen 400" and "cetirizine 10" (and its misspelling)',
    pg_temp.exact('ibuprofen 400') || ' / ' || pg_temp.exact('cetirizine 10') || ' / ' || pg_temp.exact('cetrizine 10'), 'IBU-400-10 / CET-10-10 / CET-10-10');
  PERFORM pg_temp.expect_value('a typo still finds the generic, but not as an exact match', pg_temp.exact('paracetmol 650') || ' ' || pg_temp.top('paracetmol 650'), 'none 0.72');
  PERFORM pg_temp.expect_value('Febrinil and Meridol-P are not claimed to be plain paracetamol',
    (SELECT count(*)::text FROM meridian.products WHERE sku IN ('FEB-650-10', 'MERP-650-10') AND generic IS NOT NULL), '0');
  PERFORM pg_temp.expect_value('a competitor brand is still not a match (below the 0.4 floor)', pg_temp.top('Dolo 650'), '0.31');
  PERFORM pg_temp.expect_value('brand names match as before', pg_temp.exact('meridol 650') || ' / ' || pg_temp.exact('febrinil'), 'MER-650-10,MER-650-15 / FEB-650-10');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'intake checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% intake check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
