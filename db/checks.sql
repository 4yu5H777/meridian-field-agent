-- =============================================================================
-- Meridian: verification queries and guard tests.
-- Wrapped in BEGIN ... ROLLBACK: the guard tests try to write, and nothing here
-- is ever kept. Safe to run against the live database at any time.
-- =============================================================================
BEGIN;
SET LOCAL search_path = meridian, public;

-- ---------------------------------------------------------------------------
-- A. Tables exist, and row counts
-- ---------------------------------------------------------------------------
SELECT 'areas' AS "table", count(*) AS "rows" FROM areas
UNION ALL SELECT 'users', count(*) FROM users
UNION ALL SELECT 'user_contacts', count(*) FROM user_contacts
UNION ALL SELECT 'chemists', count(*) FROM chemists
UNION ALL SELECT 'chemist_aliases', count(*) FROM chemist_aliases
UNION ALL SELECT 'route_stops', count(*) FROM route_stops
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'product_aliases', count(*) FROM product_aliases
UNION ALL SELECT 'price_list', count(*) FROM price_list
UNION ALL SELECT 'schemes', count(*) FROM schemes
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_lines', count(*) FROM order_lines
UNION ALL SELECT 'order_status_history', count(*) FROM order_status_history
UNION ALL SELECT 'credit_ledger', count(*) FROM credit_ledger
UNION ALL SELECT 'credit_approvals', count(*) FROM credit_approvals
UNION ALL SELECT 'distributor_events', count(*) FROM distributor_events
UNION ALL SELECT 'audit_log', count(*) FROM audit_log;

-- Org shape: 1 regional head, 8 managers, 50 reps; reps per manager.
SELECT role, count(*) FROM users GROUP BY role ORDER BY 2;
SELECT a.name AS area, m.full_name AS manager, count(r.id) AS reps
FROM users m JOIN areas a ON a.id = m.area_id
LEFT JOIN users r ON r.reports_to_id = m.id AND r.role = 'rep'
WHERE m.role = 'area_manager' GROUP BY a.id, m.full_name ORDER BY a.id;

-- Order history spans two weeks; status mix.
SELECT min(order_date)::text AS first_day, max(order_date)::text AS last_day, count(*) AS orders FROM orders;
SELECT status, count(*) FROM orders GROUP BY status ORDER BY 2 DESC;

-- ---------------------------------------------------------------------------
-- B. Identity and visibility
-- ---------------------------------------------------------------------------
-- Imran: old number resolves to nobody; new number resolves to him.
SELECT uc.value AS number, uc.valid_to IS NULL AS is_current,
       (SELECT full_name FROM resolve_sender('whatsapp', uc.value)) AS resolves_to
FROM user_contacts uc JOIN users u ON u.id = uc.user_id
WHERE u.employee_code = 'REP-NDL-02' AND uc.channel = 'whatsapp' ORDER BY uc.valid_from;

-- Unknown number -> zero rows. Messy email formatting still resolves.
SELECT 'unknown number' AS probe, count(*) AS matches FROM resolve_sender('whatsapp', '+91 99999 12345')
UNION ALL
SELECT 'VIKRAM.Malhotra@Meridian.example (messy case)', count(*) FROM resolve_sender('email', '  VIKRAM.Malhotra@Meridian.example ');

-- Who sees how many reps.
SELECT u.full_name, u.role, (SELECT count(*) FROM visible_rep_ids(u.id)) AS visible_reps
FROM users u WHERE u.employee_code IN ('REP-NDL-01', 'ASM-NDL', 'ASM-SDL', 'RH-NORTH') ORDER BY 3;

-- ---------------------------------------------------------------------------
-- C. Aliases and matching (rep-scoped)
-- ---------------------------------------------------------------------------
SELECT 'Ravi: "Sharma Med."' AS query, m.* FROM match_chemist((SELECT id FROM users WHERE employee_code = 'REP-NDL-01'), 'Sharma Med.') m
UNION ALL
SELECT 'Ravi: "शर्मा मेडिकल"', m.* FROM match_chemist((SELECT id FROM users WHERE employee_code = 'REP-NDL-01'), 'शर्मा मेडिकल') m
UNION ALL
SELECT 'Ravi: "sharma ji"', m.* FROM match_chemist((SELECT id FROM users WHERE employee_code = 'REP-NDL-01'), 'sharma ji') m
UNION ALL
SELECT 'Priya: "sharma"', m.* FROM match_chemist((SELECT id FROM users WHERE employee_code = 'REP-SDL-01'), 'sharma') m;

-- "650": Ravi's learned meaning wins; for Neha it is genuinely ambiguous.
SELECT 'Ravi: "650"' AS query, m.* FROM (SELECT * FROM match_product((SELECT id FROM users WHERE employee_code = 'REP-NDL-01'), '650') LIMIT 1) m
UNION ALL
SELECT 'Neha: "meridol 650"', m.* FROM match_product((SELECT id FROM users WHERE employee_code = 'REP-GGN-01'), 'meridol 650') m;

-- One letter apart: both names return both products; the scores tell them apart.
SELECT 'merilax' AS query, m.* FROM match_product(NULL, 'merilax') m
UNION ALL SELECT 'merilex', m.* FROM match_product(NULL, 'merilex') m;

-- ---------------------------------------------------------------------------
-- D. Price, schemes, exact totals
-- ---------------------------------------------------------------------------
-- Today's unconfirmed order at Verma Chemists: every scheme case on one summary.
SELECT p.name, p.pack, l.qty, rupees(l.unit_price_paise) AS unit_rs, l.free_qty,
       rupees(l.discount_paise) AS discount_rs, rupees(l.line_total_paise) AS line_rs, s.name AS scheme
FROM orders o JOIN chemists c ON c.id = o.chemist_id AND c.code = 'CH-13'
JOIN order_lines l ON l.order_id = o.id JOIN products p ON p.id = l.product_id
LEFT JOIN schemes s ON s.id = l.scheme_id
WHERE o.status = 'awaiting_confirmation' ORDER BY l.line_no;

-- Kofset DX scheme starts tomorrow -> not applied today.
SELECT code, starts_on::text, ends_on::text, starts_on = ist_date(now()) + 1 AS starts_tomorrow FROM schemes ORDER BY starts_on;

-- Kofset Syrup price change: orders before and after the change date use different prices.
SELECT pl.effective_from::text, pl.effective_to::text, rupees(pl.unit_price_paise) AS price_rs, count(l.*) AS lines_priced
FROM price_list pl LEFT JOIN order_lines l ON l.price_list_id = pl.id
WHERE pl.product_id = (SELECT id FROM products WHERE sku = 'KOF-SYP-100')
GROUP BY pl.id ORDER BY pl.effective_from;

-- Independent recomputation of every line from price_list + schemes, written
-- separately from the trigger. Any mismatch would show as a non-zero count.
SELECT count(*) AS lines_checked,
       count(*) FILTER (WHERE l.unit_price_paise <> pl.unit_price_paise) AS price_mismatches,
       count(*) FILTER (WHERE l.free_qty <> CASE WHEN s.scheme_type = 'buy_x_get_y' THEN (l.qty / s.buy_qty) * s.free_qty ELSE 0 END) AS free_qty_mismatches,
       count(*) FILTER (WHERE l.line_total_paise <> l.qty * pl.unit_price_paise
                          - CASE WHEN s.scheme_type = 'percent_off' THEN (l.qty::bigint * pl.unit_price_paise * s.discount_bp) / 10000 ELSE 0 END) AS total_mismatches
FROM order_lines l
JOIN orders o ON o.id = l.order_id
JOIN price_list pl ON pl.product_id = l.product_id AND o.order_date >= pl.effective_from
                  AND (pl.effective_to IS NULL OR o.order_date < pl.effective_to)
LEFT JOIN schemes s ON s.product_id = l.product_id AND o.order_date BETWEEN s.starts_on AND s.ends_on;

-- Money columns are integers, not floats.
SELECT table_name, column_name, data_type FROM information_schema.columns
WHERE table_schema = 'meridian' AND column_name LIKE '%paise%' AND table_name NOT LIKE 'v\_%' ORDER BY 1, 2;

-- ---------------------------------------------------------------------------
-- E. Credit
-- ---------------------------------------------------------------------------
-- "Which chemists in north are over their limit" (as the regional head would ask).
SELECT name, rupees(credit_limit_paise) AS limit_rs, rupees(owed_paise) AS owed_rs, rupees(headroom_paise) AS headroom_rs
FROM v_chemist_credit WHERE area_code = 'NDL' AND is_over_limit;

-- Ledger integrity: every order the distributor has seen carries exactly one
-- charge equal to what the rep confirmed; every distributor rejection is reversed.
SELECT count(*) AS orders_sent,
       count(*) FILTER (WHERE ch.amount_paise = o.confirmed_total_paise) AS charged_correctly,
       count(*) FILTER (WHERE o.status = 'distributor_rejected') AS rejected_by_distributor,
       count(*) FILTER (WHERE o.status = 'distributor_rejected' AND rv.amount_paise = -ch.amount_paise) AS reversed_correctly
FROM orders o
LEFT JOIN credit_ledger ch ON ch.order_id = o.id AND ch.entry_type = 'order_charge'
LEFT JOIN credit_ledger rv ON rv.order_id = o.id AND rv.entry_type = 'order_reversal'
WHERE o.status IN ('submitted', 'accepted', 'dispatched', 'distributor_rejected');

-- Approvals: who decided, and that each one was tied to one order at one total.
SELECT a.token, c.name AS chemist, a.status, m.full_name AS approver_on_record,
       d.full_name AS decided_by, rupees(a.order_total_paise) AS for_total_rs, o.status AS order_status
FROM credit_approvals a JOIN orders o ON o.id = a.order_id JOIN chemists c ON c.id = o.chemist_id
JOIN users m ON m.id = a.manager_id LEFT JOIN users d ON d.id = a.decided_by_user_id
ORDER BY a.requested_at;

-- ---------------------------------------------------------------------------
-- F. Duplicates, off-route, callbacks, audit
-- ---------------------------------------------------------------------------
SELECT o.order_id AS order_id, o.rep_name, o.chemist_name, o.status, o.duplicate_of_order_id,
       find_possible_duplicate(o.order_id) AS function_says
FROM v_orders o WHERE o.duplicate_of_order_id IS NOT NULL;

SELECT rep_name, chemist_name, order_date::text, extract(isodow FROM order_date) AS weekday, status
FROM v_orders WHERE is_off_route ORDER BY order_date DESC LIMIT 8;

SELECT result, count(*) AS events, sum(times_received) AS deliveries FROM distributor_events GROUP BY result ORDER BY 2 DESC;

-- Full trail for one order that needed approval.
SELECT h.order_id, h.from_status, h.to_status, (h.changed_at AT TIME ZONE 'Asia/Kolkata')::text AS at_ist, h.actor
FROM order_status_history h
WHERE h.order_id = (SELECT order_id FROM credit_approvals WHERE status = 'approved' ORDER BY requested_at LIMIT 1)
ORDER BY h.id;

SELECT action, count(*) FROM audit_log GROUP BY action ORDER BY 1;

-- ---------------------------------------------------------------------------
-- G. Manager questions (the 8 o'clock question), all scoped by visible_rep_ids
-- ---------------------------------------------------------------------------
-- "Why is Ravi down this week?" -> last 7 days vs the 7 before.
-- "Sold" = the distributor has it and has not rejected it.
SELECT rep_name,
       count(*) FILTER (WHERE order_date >= ist_date(now()) - 7 AND order_date < ist_date(now())) AS orders_last_7d,
       count(*) FILTER (WHERE order_date >= ist_date(now()) - 14 AND order_date < ist_date(now()) - 7) AS orders_prev_7d,
       rupees(coalesce(sum(total_paise) FILTER (WHERE order_date >= ist_date(now()) - 7 AND order_date < ist_date(now())
                                  AND status IN ('submitted', 'accepted', 'dispatched')), 0)::bigint) AS sold_last_7d_rs,
       rupees(coalesce(sum(total_paise) FILTER (WHERE order_date >= ist_date(now()) - 14 AND order_date < ist_date(now()) - 7
                                  AND status IN ('submitted', 'accepted', 'dispatched')), 0)::bigint) AS sold_prev_7d_rs,
       count(*) FILTER (WHERE order_date >= ist_date(now()) - 7 AND status = 'credit_rejected') AS credit_rejected_last_7d
FROM v_orders
WHERE rep_id IN (SELECT visible_rep_ids((SELECT id FROM users WHERE employee_code = 'ASM-NDL')))
GROUP BY rep_name ORDER BY rep_name;

-- Evening summary inputs for each manager, today.
SELECT m.full_name AS manager,
       count(o.order_id) FILTER (WHERE o.order_date = ist_date(now())) AS orders_today,
       rupees(coalesce(sum(o.total_paise) FILTER (WHERE o.order_date = ist_date(now()) AND o.status NOT IN ('draft', 'cancelled')), 0)::bigint) AS value_today_rs,
       count(o.order_id) FILTER (WHERE o.order_date = ist_date(now()) AND o.is_off_route) AS off_route_today,
       (SELECT count(*) FROM credit_approvals a WHERE a.manager_id = m.id AND a.status = 'pending') AS waiting_on_manager
FROM users m LEFT JOIN v_orders o ON o.manager_id = m.id
WHERE m.role = 'area_manager' GROUP BY m.id ORDER BY m.id;

-- Can a manager's question be served by an index? At seed size (~70 orders)
-- the planner rightly prefers a sequential scan, so it is disabled for this one
-- statement to show that orders_rep_created_idx CAN serve it. At 100k orders
-- the planner chooses the index without being told.
SET LOCAL enable_seqscan = off;
EXPLAIN SELECT count(*) FROM orders
WHERE rep_id IN (SELECT visible_rep_ids((SELECT id FROM users WHERE employee_code = 'ASM-NDL')))
  AND created_at >= now() - interval '7 days';


-- =============================================================================
-- H. Guard tests: try to break each rule. PASS means the database refused.
-- =============================================================================
CREATE OR REPLACE FUNCTION pg_temp.expect_guard(p_name text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE NOTICE 'FAIL  %: statement was allowed', p_name;
  EXCEPTION WHEN others THEN
    -- GUARD: = our triggers; 23P01 = exclusion constraint; 23505 = unique index.
    IF SQLERRM LIKE 'GUARD:%' OR SQLSTATE IN ('23P01', '23505') THEN
      RAISE NOTICE 'PASS  %  ->  %', p_name, SQLERRM;
    ELSE
      RAISE NOTICE 'FAIL  %: unexpected error %', p_name, SQLERRM;
    END IF;
  END;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.expect_value(p_name text, p_got text, p_want text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_got IS NOT DISTINCT FROM p_want THEN
    RAISE NOTICE 'PASS  %  ->  %', p_name, p_got;
  ELSE
    RAISE NOTICE 'FAIL  %: got %, want %', p_name, p_got, p_want;
  END IF;
END $$;

DO $tests$
DECLARE
  v_draft    bigint := (SELECT o.id FROM orders o WHERE o.status = 'draft' LIMIT 1);
  v_unconf   bigint := (SELECT o.id FROM orders o WHERE o.status = 'awaiting_confirmation' AND duplicate_of_order_id IS NULL LIMIT 1);
  v_pending  bigint := (SELECT order_id FROM credit_approvals WHERE status = 'pending' LIMIT 1);
  v_token    text   := (SELECT token FROM credit_approvals WHERE status = 'pending' LIMIT 1);
  v_disp     bigint := (SELECT o.id FROM orders o WHERE o.status = 'dispatched' LIMIT 1);
  v_ref      text;
  v_evt      text;
  v_price    bigint;
BEGIN
  RAISE NOTICE '--- confirmation ---';
  PERFORM pg_temp.expect_guard('draft straight to distributor',
    format($q$UPDATE meridian.orders SET status = 'submitted', submitted_at = now(), distributor_ref = 'X1',
             rep_confirmed_at = now(), confirmed_total_paise = 1, confirmed_lines_hash = 'x' WHERE id = %s$q$, v_draft));
  PERFORM pg_temp.expect_guard('unconfirmed order marked confirmed',
    format($q$UPDATE meridian.orders SET status = 'confirmed' WHERE id = %s$q$, v_unconf));
  PERFORM pg_temp.expect_guard('confirmation claimed for a different total',
    format($q$UPDATE meridian.orders SET status = 'confirmed', rep_confirmed_at = now(),
             confirmed_total_paise = 100, confirmed_lines_hash = meridian.order_lines_hash(id) WHERE id = %s$q$, v_unconf));
  PERFORM pg_temp.expect_guard('order created already submitted',
    $q$INSERT INTO meridian.orders (rep_id, chemist_id, channel, input_type, status)
       SELECT rep_id, chemist_id, 'whatsapp', 'text', 'submitted' FROM meridian.route_stops LIMIT 1$q$);

  RAISE NOTICE '--- credit ---';
  PERFORM pg_temp.expect_guard('over-limit order confirmed without approval',
    format($q$UPDATE meridian.orders SET status = 'confirmed' WHERE id = %s$q$, v_pending));
  PERFORM pg_temp.expect_guard('line added after rep confirmed',
    format($q$INSERT INTO meridian.order_lines (order_id, line_no, product_id, qty) VALUES (%s, 99, 1, 1)$q$, v_pending));
  PERFORM pg_temp.expect_value('approval by forwarded colleague',
    decide_credit_approval(v_token, 'pooja.bhatia@meridian.example', 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('approval by unknown email',
    decide_credit_approval(v_token, 'someone@gmail.com', 'approved'), 'not_authorized');
  PERFORM pg_temp.expect_value('approval by the right manager',
    decide_credit_approval(v_token, 'Vikram.Malhotra@meridian.example', 'approved', 'ok'), 'approved');
  PERFORM pg_temp.expect_value('order status after approval',
    (SELECT status FROM orders WHERE id = v_pending), 'confirmed');
  PERFORM pg_temp.expect_value('second reply to the same thread',
    decide_credit_approval(v_token, 'vikram.malhotra@meridian.example', 'rejected'), 'already_decided');

  RAISE NOTICE '--- price ---';
  INSERT INTO order_lines (order_id, line_no, product_id, qty, unit_price_paise, price_list_id, discount_paise)
  VALUES (v_draft, 50, (SELECT id FROM products WHERE sku = 'MUL-15'), 3, 1, 1, 0)
  RETURNING unit_price_paise INTO v_price;
  PERFORM pg_temp.expect_value('rep-quoted price of 0.01 ignored; list price used',
    v_price::text, (SELECT unit_price_paise::text FROM price_list pl JOIN products p ON p.id = pl.product_id
                    WHERE p.sku = 'MUL-15' AND pl.effective_to IS NULL));
  PERFORM pg_temp.expect_guard('overlapping price for one product',
    $q$INSERT INTO meridian.price_list (product_id, unit_price_paise, effective_from)
       SELECT product_id, 1, effective_from + 1 FROM meridian.price_list LIMIT 1$q$);
  PERFORM pg_temp.expect_guard('second scheme on the same product and dates',
    $q$INSERT INTO meridian.schemes (code, name, product_id, scheme_type, discount_bp, starts_on, ends_on)
       SELECT 'X', 'x', product_id, 'percent_off', 100, starts_on, ends_on FROM meridian.schemes LIMIT 1$q$);

  RAISE NOTICE '--- identity / scope ---';
  PERFORM pg_temp.expect_guard('rep orders for another rep''s chemist',
    $q$INSERT INTO meridian.orders (rep_id, chemist_id, channel, input_type)
       SELECT (SELECT id FROM meridian.users WHERE employee_code = 'REP-NDL-01'),
              (SELECT id FROM meridian.chemists WHERE code = 'CH-06'), 'whatsapp', 'text'$q$);
  PERFORM pg_temp.expect_guard('number given two current owners',
    $q$INSERT INTO meridian.user_contacts (user_id, channel, value)
       SELECT 1, channel, value FROM meridian.user_contacts WHERE valid_to IS NULL AND user_id <> 1 LIMIT 1$q$);

  RAISE NOTICE '--- distributor callbacks ---';
  SELECT distributor_ref INTO v_ref FROM orders WHERE id = v_disp;
  SELECT distributor_event_id INTO v_evt FROM distributor_events WHERE order_id = v_disp AND status_normalized = 'dispatched' LIMIT 1;
  PERFORM pg_temp.expect_value('same dispatched event replayed',
    record_distributor_event(v_evt, v_ref, 'DISPATCHED', now(), '{}'), 'duplicate');
  PERFORM pg_temp.expect_value('late ACCEPTED after DISPATCHED',
    record_distributor_event('T-late-' || v_ref, v_ref, 'ACCEPTED', now(), '{}'), 'ignored_out_of_order');
  PERFORM pg_temp.expect_value('status never seen before',
    record_distributor_event('T-odd-' || v_ref, v_ref, 'LOST_IN_TRANSIT', now(), '{}'), 'unknown_status');
  PERFORM pg_temp.expect_value('callback for an order we never sent',
    record_distributor_event('T-ghost', 'DST-999999', 'DISPATCHED', now(), '{}'), 'unknown_order');
  PERFORM pg_temp.expect_value('order still dispatched after all that',
    (SELECT status FROM orders WHERE id = v_disp), 'dispatched');

  RAISE NOTICE '--- audit ---';
  PERFORM pg_temp.expect_guard('rewrite audit log', 'UPDATE meridian.audit_log SET action = ''x''');
  PERFORM pg_temp.expect_guard('delete a ledger entry', 'DELETE FROM meridian.credit_ledger');
  PERFORM pg_temp.expect_guard('rewrite status history', 'DELETE FROM meridian.order_status_history');
  -- These run as the owner login, which HAS the TRUNCATE privilege: the
  -- statement triggers must refuse anyway.
  PERFORM pg_temp.expect_guard('truncate audit log (as owner)', 'TRUNCATE meridian.audit_log');
  PERFORM pg_temp.expect_guard('truncate ledger (as owner)', 'TRUNCATE meridian.credit_ledger');
  PERFORM pg_temp.expect_guard('truncate status history (as owner)', 'TRUNCATE meridian.order_status_history');
  PERFORM pg_temp.expect_guard('truncate distributor events (as owner)', 'TRUNCATE meridian.distributor_events');

  RAISE NOTICE '--- seed clock (owner login only; see checks-*.sql for the runtime roles) ---';
  PERFORM set_config('meridian.now', '2020-01-01 12:00+00', true);
  PERFORM pg_temp.expect_value('owner login can still set meridian.now', app_now()::date::text, '2020-01-01');
  PERFORM set_config('meridian.now', '', true);
END $tests$;

ROLLBACK;
