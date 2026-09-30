-- =============================================================================
-- Manager / regional-head questions (meridian_report): scope by role, exact
-- figures (recomputed independently here), unauthorized access, unknown sender.
--   node --env-file=.env.owner scripts/db.mjs db/checks-reports.sql
-- Owner login, BEGIN ... ROLLBACK. Non-zero exit on failure.
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

CREATE FUNCTION pg_temp.email(p_code text) RETURNS text LANGUAGE sql AS $$
  SELECT uc.value FROM meridian.user_contacts uc JOIN meridian.users u ON u.id = uc.user_id
   WHERE u.employee_code = p_code AND uc.channel = 'email' AND uc.valid_to IS NULL ORDER BY uc.id LIMIT 1 $$;
CREATE FUNCTION pg_temp.ask(p_code text, p_report text, p_params jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $$
  SELECT meridian.meridian_report('email', ARRAY[pg_temp.email(p_code)], p_report, p_params) $$;
-- Independent: reps under a manager ('ALL' = everyone), without visible_rep_ids().
CREATE FUNCTION pg_temp.team(p_mgr text) RETURNS SETOF bigint LANGUAGE sql AS $$
  SELECT r.id FROM meridian.users r JOIN meridian.users m ON m.id = r.reports_to_id
   WHERE r.role = 'rep' AND (m.employee_code = p_mgr OR p_mgr = 'ALL') $$;
CREATE FUNCTION pg_temp.counts(p_reps bigint[], p_from date, p_to date) RETURNS text LANGUAGE sql AS $$
  SELECT count(*) || '/' || coalesce(sum(confirmed_total_paise) FILTER (WHERE status NOT IN ('credit_rejected', 'distributor_rejected', 'cancelled')), 0)
    FROM meridian.orders WHERE rep_id = ANY (p_reps) AND order_date BETWEEN p_from AND p_to AND rep_confirmed_at IS NOT NULL $$;

DO $t$
DECLARE
  d date := ist_date(now());
  j jsonb;
  ndl bigint[] := ARRAY(SELECT pg_temp.team('ASM-NDL'));
  alls bigint[] := ARRAY(SELECT pg_temp.team('ALL'));
  ravi bigint := (SELECT id FROM users WHERE employee_code = 'REP-NDL-01');
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  RAISE NOTICE '--- 1. team order counts (manager: own team only) ---';
  j := pg_temp.ask('ASM-NDL', 'orders_summary', '{"period":"today"}');
  PERFORM pg_temp.expect_value('Vikram: today''s orders and value', (j->'data'->>'orders') || '/' || (j->'data'->>'value_paise'), pg_temp.counts(ndl, d, d));
  PERFORM pg_temp.expect_value('scope is own team', (j->>'scope') || ' / ' || (j->'period'->>'from') || '..' || (j->'period'->>'to'), 'own team / ' || d || '..' || d);
  PERFORM pg_temp.expect_value('only North Delhi reps listed',
    (SELECT count(*)::text FROM jsonb_array_elements(j->'data'->'reps') r WHERE r->>'area' <> 'North Delhi'), '0');
  j := pg_temp.ask('ASM-NDL', 'orders_summary', '{"period":"last_7_days"}');
  PERFORM pg_temp.expect_value('Vikram: last 7 days', (j->'data'->>'orders') || '/' || (j->'data'->>'value_paise'), pg_temp.counts(ndl, d - 6, d));

  RAISE NOTICE '--- 2. value and status breakdown ---';
  PERFORM pg_temp.expect_value('status breakdown adds up', (SELECT sum(value::int)::text FROM jsonb_each_text(j->'data'->'by_status')), j->'data'->>'orders');
  PERFORM pg_temp.expect_value('credit-rejected count matches',
    coalesce(j->'data'->'by_status'->>'credit_rejected', '0'),
    (SELECT count(*)::text FROM orders WHERE rep_id = ANY (ndl) AND order_date BETWEEN d - 6 AND d AND status = 'credit_rejected'));
  PERFORM pg_temp.expect_value('per-rep values add up to the team value',
    (SELECT coalesce(sum((r->>'value_paise')::bigint), 0)::text FROM jsonb_array_elements(j->'data'->'reps') r), j->'data'->>'value_paise');

  RAISE NOTICE '--- 3. pending credit approvals ---';
  j := pg_temp.ask('ASM-NDL', 'pending_approvals');
  PERFORM pg_temp.expect_value('Vikram''s pending approvals',
    (j->'data'->>'count') || '/' || (j->'data'->>'total_paise'),
    (SELECT count(*) || '/' || coalesce(sum(a.order_total_paise), 0) FROM credit_approvals a JOIN orders o ON o.id = a.order_id
      WHERE a.status = 'pending' AND o.status = 'awaiting_credit_approval' AND o.rep_id = ANY (ndl)));
  PERFORM pg_temp.expect_value('Pooja sees none of them', pg_temp.ask('ASM-SDL', 'pending_approvals')->'data'->>'count', '0');

  RAISE NOTICE '--- 4. dispatch status ---';
  j := pg_temp.ask('ASM-NDL', 'dispatch_status', '{"period":"last_7_days"}');
  PERFORM pg_temp.expect_value('sent / dispatched / rejected by distributor',
    (j->'data'->>'sent_to_distributor') || '/' || (j->'data'->>'dispatched') || '/' || (j->'data'->>'rejected_by_distributor'),
    (SELECT count(*) || '/' || count(*) FILTER (WHERE status = 'dispatched') || '/' || count(*) FILTER (WHERE status = 'distributor_rejected')
       FROM orders WHERE rep_id = ANY (ndl) AND order_date BETWEEN d - 6 AND d AND submitted_at IS NOT NULL));
  PERFORM pg_temp.expect_value('not-yet-dispatched list = submitted + accepted',
    jsonb_array_length(j->'data'->'not_yet_dispatched')::text,
    (SELECT least(count(*), 20)::text FROM orders WHERE rep_id = ANY (ndl) AND order_date BETWEEN d - 6 AND d AND status IN ('submitted', 'accepted')));

  RAISE NOTICE '--- 5. regional head: all teams ---';
  j := pg_temp.ask('RH-NORTH', 'orders_summary', '{"period":"last_7_days"}');
  PERFORM pg_temp.expect_value('Anjali: all teams, last 7 days', (j->>'scope') || ' ' || (j->'data'->>'orders') || '/' || (j->'data'->>'value_paise'),
    'all teams ' || pg_temp.counts(alls, d - 6, d));
  j := pg_temp.ask('RH-NORTH', 'over_limit_chemists', '{"area":"north"}');
  PERFORM pg_temp.expect_value('"which chemists in north are over their limit"',
    (SELECT string_agg(c->>'chemist', ',' ORDER BY c->>'chemist') FROM jsonb_array_elements(j->'data'->'chemists') c),
    (SELECT string_agg(name, ',' ORDER BY name) FROM v_chemist_credit WHERE area_code = 'NDL' AND is_over_limit));
  PERFORM pg_temp.expect_value('Pooja cannot see North Delhi chemists by naming the area', pg_temp.ask('ASM-SDL', 'over_limit_chemists', '{"area":"north"}')->>'error', 'area_not_found');
  j := pg_temp.ask('RH-NORTH', 'rep_comparison', '{"rep":"Ravi","period":"last_7_days"}');
  PERFORM pg_temp.expect_value('"why is Ravi down": this week vs last week',
    (j->'data'->'current'->>'orders') || ' vs ' || (j->'data'->'previous'->>'orders') || ', change ' || (j->'data'->>'change_orders'),
    (SELECT count(*) FILTER (WHERE order_date BETWEEN d - 6 AND d) || ' vs ' || count(*) FILTER (WHERE order_date BETWEEN d - 13 AND d - 7)
            || ', change ' || (count(*) FILTER (WHERE order_date BETWEEN d - 6 AND d) - count(*) FILTER (WHERE order_date BETWEEN d - 13 AND d - 7))
       FROM orders WHERE rep_id = ravi AND rep_confirmed_at IS NOT NULL));
  PERFORM pg_temp.expect_value('Ravi''s credit rejection this week is part of the answer',
    j->'data'->'current'->>'credit_rejected',
    (SELECT count(*)::text FROM orders WHERE rep_id = ravi AND order_date BETWEEN d - 6 AND d AND status = 'credit_rejected'));

  RAISE NOTICE '--- 6. unauthorized manager / rep access ---';
  PERFORM pg_temp.expect_value('Pooja asking about Ravi (not her rep)', pg_temp.ask('ASM-SDL', 'rep_comparison', '{"rep":"Ravi"}')->>'error', 'rep_not_found');
  PERFORM pg_temp.expect_value('... or by his employee code', pg_temp.ask('ASM-SDL', 'orders_summary', '{"rep":"REP-NDL-01"}')->>'error', 'rep_not_found');
  j := pg_temp.ask('REP-NDL-01', 'orders_summary', '{"period":"last_7_days"}');
  PERFORM pg_temp.expect_value('a rep asking for team figures gets only their own',
    (j->>'scope') || ' ' || (j->'data'->>'orders') || '/' || (j->'data'->>'value_paise'), 'own orders ' || pg_temp.counts(ARRAY[ravi], d - 6, d));
  PERFORM pg_temp.expect_value('a rep asking about another rep', pg_temp.ask('REP-NDL-01', 'orders_summary', '{"rep":"Imran"}')->>'error', 'rep_not_found');
  PERFORM pg_temp.expect_value('a rep sees no other rep''s pending approvals',
    pg_temp.ask('REP-NDL-01', 'pending_approvals')->'data'->>'count',
    (SELECT count(*)::text FROM credit_approvals a JOIN orders o ON o.id = a.order_id WHERE a.status = 'pending' AND o.rep_id = ravi));

  RAISE NOTICE '--- 7. unknown sender, bad input ---';
  PERFORM pg_temp.expect_value('unknown sender', meridian_report('email', ARRAY['stranger@gmail.com'], 'orders_summary', '{}')->>'error', 'not_identified');
  PERFORM pg_temp.expect_value('two people''s contacts', meridian_report('email', ARRAY[pg_temp.email('ASM-NDL'), pg_temp.email('ASM-SDL')], 'orders_summary', '{}')->>'error', 'not_identified');
  PERFORM pg_temp.expect_value('wrong channel', meridian_report('web', ARRAY[pg_temp.email('ASM-NDL')], 'orders_summary', '{}')->>'error', 'not_identified');
  PERFORM pg_temp.expect_value('a report that does not exist', pg_temp.ask('ASM-NDL', 'SELECT * FROM users')->>'error', 'bad_report');
  PERFORM pg_temp.expect_value('an unknown period', pg_temp.ask('ASM-NDL', 'orders_summary', '{"period":"forever"}')->>'error', 'bad_period');
  PERFORM pg_temp.expect_value('custom range longer than 92 days', pg_temp.ask('ASM-NDL', 'orders_summary', jsonb_build_object('period', 'custom', 'from', d - 200, 'to', d))->>'error', 'bad_period');
  PERFORM pg_temp.expect_value('custom range in the future', pg_temp.ask('ASM-NDL', 'orders_summary', jsonb_build_object('period', 'custom', 'from', d, 'to', d + 3))->>'error', 'bad_period');
  PERFORM pg_temp.expect_value('custom dates that are not dates', pg_temp.ask('ASM-NDL', 'orders_summary', '{"period":"custom","from":"x; DROP","to":"y"}')->>'error', 'bad_period');
  PERFORM pg_temp.expect_value('a valid custom range', pg_temp.ask('ASM-NDL', 'orders_summary', jsonb_build_object('period', 'custom', 'from', d - 3, 'to', d - 1))->'data'->>'orders',
    split_part(pg_temp.counts(ndl, d - 3, d - 1), '/', 1));
  PERFORM pg_temp.expect_value('comparison needs a rep', pg_temp.ask('ASM-NDL', 'rep_comparison')->>'error', 'rep_required');
  -- A second "Ravi" in North Delhi (rolled back): asking about "Ravi" must not guess.
  INSERT INTO users (employee_code, full_name, role, area_id, reports_to_id)
  SELECT 'REP-NDL-99', 'Ravi Verma', 'rep', area_id, id FROM users WHERE employee_code = 'ASM-NDL';
  PERFORM pg_temp.expect_value('a first name matching two reps is ambiguous, with both names',
    (SELECT (j2->>'error') || ': ' || (j2->'candidates'->>0) || ', ' || (j2->'candidates'->>1)
       FROM (SELECT pg_temp.ask('ASM-NDL', 'rep_comparison', '{"rep":"ravi"}') AS j2) x), 'ambiguous_rep: Ravi Kumar, Ravi Verma');
  PERFORM pg_temp.expect_value('the full name still resolves exactly',
    pg_temp.ask('ASM-NDL', 'rep_comparison', '{"rep":"Ravi Kumar"}')->'data'->>'rep', 'Ravi Kumar');
  PERFORM pg_temp.expect_value('lists are capped at 20 rows',
    (SELECT (jsonb_array_length(pg_temp.ask('RH-NORTH', 'orders_summary', '{"period":"last_7_days"}')->'data'->'reps') <= 20)::text), 'true');
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'report checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% report check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
