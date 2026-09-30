-- =============================================================================
-- "It has to still work at a hundred thousand orders" (Assignment B, section 05)
--
-- Inserts 100,000 extra orders (through the real insert trigger), refreshes
-- planner statistics, and times a manager's question. Everything is rolled
-- back: the live data is unchanged afterwards.
-- =============================================================================
BEGIN;
SET LOCAL search_path = meridian, public;
SELECT set_config('meridian.actor', 'scale-check', true);

-- Spread 100k draft orders over the last 180 days across every rep/chemist pair.
INSERT INTO orders (rep_id, chemist_id, channel, input_type, created_at)
SELECT p.rep_id, p.chemist_id, 'whatsapp', 'text', now() - (g % 180) * interval '1 day' - (g % 600) * interval '1 minute'
FROM (SELECT DISTINCT rep_id, chemist_id FROM route_stops) p
CROSS JOIN generate_series(1, 100000 / (SELECT count(DISTINCT (rep_id, chemist_id)) FROM route_stops)) g;

ANALYZE orders;

SELECT count(*) AS orders_now FROM orders;

-- Vikram's "how did my reps do this week", as a tool would run it.
EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT r.full_name, count(*) AS orders_7d
FROM orders o JOIN users r ON r.id = o.rep_id
WHERE o.rep_id IN (SELECT visible_rep_ids((SELECT id FROM users WHERE employee_code = 'ASM-NDL')))
  AND o.created_at >= now() - interval '7 days'
GROUP BY r.full_name;

ROLLBACK;
