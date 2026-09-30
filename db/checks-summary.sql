-- =============================================================================
-- Evening summary: scope, figures (each recomputed independently here),
-- waiting approvals, off-route orders, an empty team, the regional head, and
-- the 7 PM queueing (IST date, once per recipient per day).
--   node --env-file=.env.owner scripts/db.mjs db/checks-summary.sql
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

-- Independent recomputation, written without evening_summary() or visible_rep_ids().
CREATE FUNCTION pg_temp.team_reps(p_mgr text) RETURNS SETOF bigint
LANGUAGE sql AS $$
  SELECT r.id FROM meridian.users r JOIN meridian.users m ON m.id = r.reports_to_id
   WHERE r.role = 'rep' AND (m.employee_code = p_mgr OR p_mgr = 'ALL')
$$;
CREATE FUNCTION pg_temp.expected(p_mgr text, p_date date) RETURNS text
LANGUAGE sql AS $$
  SELECT count(*) || ' orders, ' || coalesce(sum(o.confirmed_total_paise) FILTER (WHERE o.status NOT IN ('credit_rejected', 'distributor_rejected', 'cancelled')), 0)
         || ' paise, ' || count(*) FILTER (WHERE o.is_off_route) || ' off-route'
    FROM meridian.orders o
   WHERE o.order_date = p_date AND o.rep_confirmed_at IS NOT NULL AND o.rep_id IN (SELECT pg_temp.team_reps(p_mgr))
$$;
CREATE FUNCTION pg_temp.got(s jsonb) RETURNS text
LANGUAGE sql AS $$ SELECT (s->'team'->>'orders') || ' orders, ' || (s->'team'->>'value_paise') || ' paise, ' || (s->'team'->>'off_route') || ' off-route' $$;
CREATE FUNCTION pg_temp.uid(p_code text) RETURNS bigint LANGUAGE sql AS $$ SELECT id FROM meridian.users WHERE employee_code = p_code $$;

DO $t$
DECLARE
  v_today date := ist_date(now());
  s_ndl jsonb := evening_summary(pg_temp.uid('ASM-NDL'), ist_date(now()));   -- Vikram: Ravi, Imran, ...
  s_sdl jsonb := evening_summary(pg_temp.uid('ASM-SDL'), ist_date(now()));   -- Pooja: Priya (off-route), Sunil
  s_wdl jsonb := evening_summary(pg_temp.uid('ASM-WDL'), ist_date(now()));   -- Sunita: a team with no chemists
  s_rh  jsonb := evening_summary(pg_temp.uid('RH-NORTH'), ist_date(now()));
  n integer;
BEGIN
  RAISE NOTICE 'connected as %', session_user;

  RAISE NOTICE '--- manager isolation ---';
  PERFORM pg_temp.expect_value('Vikram''s reps are exactly his 7',
    (SELECT string_agg(x->>'code', ',' ORDER BY x->>'code') FROM jsonb_array_elements(s_ndl->'reps') x),
    (SELECT string_agg(employee_code, ',' ORDER BY employee_code) FROM users WHERE id IN (SELECT pg_temp.team_reps('ASM-NDL'))));
  PERFORM pg_temp.expect_value('no rep from another area in Vikram''s email',
    (SELECT count(*)::text FROM jsonb_array_elements(s_ndl->'reps') x WHERE x->>'area' <> 'North Delhi'), '0');
  PERFORM pg_temp.expect_value('Pooja''s email has none of Vikram''s reps',
    (SELECT count(*)::text FROM jsonb_array_elements(s_sdl->'reps') x WHERE x->>'code' LIKE 'REP-NDL-%'), '0');

  RAISE NOTICE '--- correct totals and counts (independent recomputation) ---';
  PERFORM pg_temp.expect_value('North Delhi today', pg_temp.got(s_ndl), pg_temp.expected('ASM-NDL', v_today));
  PERFORM pg_temp.expect_value('South Delhi today', pg_temp.got(s_sdl), pg_temp.expected('ASM-SDL', v_today));
  PERFORM pg_temp.expect_value('per-rep values add up to the team value',
    (SELECT sum((x->>'value_paise')::bigint)::text FROM jsonb_array_elements(s_ndl->'reps') x), s_ndl->'team'->>'value_paise');
  PERFORM pg_temp.expect_value('status breakdown adds up to the order count',
    (SELECT coalesce(sum(value::int), 0)::text FROM jsonb_each_text(s_ndl->'team'->'by_status')), s_ndl->'team'->>'orders');
  PERFORM pg_temp.expect_value('an earlier day is summarised for that day',
    pg_temp.got(evening_summary(pg_temp.uid('ASM-NDL'), v_today - 2)), pg_temp.expected('ASM-NDL', v_today - 2));

  RAISE NOTICE '--- waiting on the manager ---';
  PERFORM pg_temp.expect_value('Vikram''s pending approvals (the forwarded Jain Medicos request)',
    (SELECT string_agg(x->>'token', ',' ORDER BY x->>'token') FROM jsonb_array_elements(s_ndl->'waiting') x),
    (SELECT string_agg(a.token, ',' ORDER BY a.token) FROM credit_approvals a JOIN users m ON m.id = a.manager_id
      WHERE m.employee_code = 'ASM-NDL' AND a.status = 'pending'));
  PERFORM pg_temp.expect_value('that request shows the chemist and how far over the limit',
    (SELECT (x->>'chemist') || ' over by ' || (x->>'over_by_paise') FROM jsonb_array_elements(s_ndl->'waiting') x LIMIT 1),
    (SELECT c.name || ' over by ' || (a.owed_paise_at_request + a.order_total_paise - a.limit_paise_at_request)
       FROM credit_approvals a JOIN orders o ON o.id = a.order_id JOIN chemists c ON c.id = o.chemist_id
       JOIN users m ON m.id = a.manager_id WHERE m.employee_code = 'ASM-NDL' AND a.status = 'pending' LIMIT 1));
  PERFORM pg_temp.expect_value('Pooja is not shown Vikram''s approvals', jsonb_array_length(s_sdl->'waiting')::text, '0');

  RAISE NOTICE '--- off-route orders ---';
  PERFORM pg_temp.expect_value('Pooja''s off-route list = her team''s off-route orders today',
    (SELECT string_agg(x->>'order_id', ',' ORDER BY (x->>'order_id')::bigint) FROM jsonb_array_elements(s_sdl->'off_route_orders') x),
    (SELECT string_agg(o.id::text, ',' ORDER BY o.id) FROM orders o WHERE o.order_date = v_today AND o.is_off_route
        AND o.rep_confirmed_at IS NOT NULL AND o.rep_id IN (SELECT pg_temp.team_reps('ASM-SDL'))));
  PERFORM pg_temp.expect_value('Priya''s deliberate off-route order is there',
    (SELECT count(*)::text FROM jsonb_array_elements(s_sdl->'off_route_orders') x WHERE x->>'rep' = 'Priya Nair'), '1');

  RAISE NOTICE '--- a team with no orders ---';
  PERFORM pg_temp.expect_value('Sunita: 6 reps, nothing else', (s_wdl->'team'->>'reps') || ' reps, ' || pg_temp.got(s_wdl), '6 reps, 0 orders, 0 paise, 0 off-route');
  PERFORM pg_temp.expect_value('empty lists, not nulls',
    jsonb_typeof(s_wdl->'waiting') || jsonb_array_length(s_wdl->'waiting') || jsonb_typeof(s_wdl->'off_route_orders') || jsonb_array_length(s_wdl->'off_route_orders'), 'array0array0');

  RAISE NOTICE '--- regional head sees everything, separately ---';
  PERFORM pg_temp.expect_value('all 50 reps', s_rh->'team'->>'reps', '50');
  PERFORM pg_temp.expect_value('all teams'' totals', pg_temp.got(s_rh), pg_temp.expected('ALL', v_today));
  PERFORM pg_temp.expect_value('all pending approvals', jsonb_array_length(s_rh->'waiting')::text,
    (SELECT count(*)::text FROM credit_approvals a JOIN orders o ON o.id = a.order_id WHERE a.status = 'pending' AND o.status = 'awaiting_credit_approval'));
  PERFORM pg_temp.expect_value('a rep or an unknown id gets no summary',
    coalesce(evening_summary(pg_temp.uid('REP-NDL-01'), v_today)::text, 'none') || '/' || coalesce(evening_summary(-1, v_today)::text, 'none'), 'none/none');

  RAISE NOTICE '--- 7 PM queueing ---';
  PERFORM set_config('meridian.now', (v_today + time '19:00') AT TIME ZONE 'Asia/Kolkata' || '', true);
  n := enqueue_evening_summaries(NULL);
  PERFORM pg_temp.expect_value('one email per area manager plus the regional head', n::text, '9');
  PERFORM pg_temp.expect_value('each goes by email to the person it describes',
    (SELECT (count(*) = 9 AND bool_and(channel = 'email' AND (payload->'viewer'->>'id')::bigint = recipient_user_id))::text
       FROM notification_outbox WHERE kind = 'evening_summary'), 'true');
  PERFORM pg_temp.expect_value('queued payload = the summary at 7 PM',
    ((SELECT payload FROM notification_outbox WHERE dedupe_key = 'evening:' || pg_temp.uid('ASM-NDL') || ':' || v_today) = s_ndl)::text, 'true');
  PERFORM pg_temp.expect_value('the job running twice (a retry) queues nothing more', enqueue_evening_summaries(NULL)::text, '0');
  -- 18:31 UTC is 00:01 the next day in India: that run is for the NEXT business date.
  PERFORM set_config('meridian.now', (v_today + time '18:31') AT TIME ZONE 'UTC' || '', true);
  n := enqueue_evening_summaries(NULL);
  PERFORM pg_temp.expect_value('the date is India''s, not UTC''s (a run at 00:01 IST is for the next day)',
    n || ' queued, ' || (SELECT count(*) FROM notification_outbox WHERE dedupe_key LIKE 'evening:%:' || (v_today + 1)) || ' for the next day',
    '9 queued, 9 for the next day');
  PERFORM set_config('meridian.now', (now() + interval '2 days')::text, true);   -- past both simulated 7 PMs
  PERFORM pg_temp.expect_value('it is delivered through the existing dispatcher',
    (SELECT count(*)::text FROM claim_notifications(100, 120) WHERE kind = 'evening_summary'), '18');
  PERFORM set_config('meridian.now', '', true);
END $t$;

DO $$
DECLARE v_pass int; v_fail int;
BEGIN
  SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok) INTO v_pass, v_fail FROM check_results;
  RAISE NOTICE 'summary checks: % passed, % failed', v_pass, v_fail;
  IF v_fail > 0 THEN RAISE EXCEPTION '% summary check(s) failed', v_fail; END IF;
END $$;

ROLLBACK;
