-- =============================================================================
-- Meridian Healthcare: demo data (run after schema.sql)
--
-- Everything is relative to today's date in India, so "a scheme that starts
-- tomorrow" and "a number that changed last week" stay true whenever this is
-- re-run. Randomness is deterministic: hashtext(<key>) instead of random(),
-- so the same run date always produces the same data.
--
-- The order history is NOT inserted as finished rows. Each order is created as
-- a draft and pushed through the real lifecycle: the pricing trigger, rep
-- confirmation, credit check, approval by the real manager's email, submission,
-- and distributor callbacks via record_distributor_event(). The only seed-only
-- trick is setting `meridian.now` so those steps get backdated timestamps.
-- If a rule were broken, this script would fail.
--
-- Deliberately awkward data (Assignment B, "Your data"):
--   * New Life Chemists (CH-03) is already over its credit limit.
--   * Kofset DX Syrup's "Buy 5 get 1 free" starts tomorrow.
--   * Sharma Medical Store has several spellings incl. Devanagari, and a
--     different chemist in another area is called "Sharma Medicos".
--   * Merilax vs Merilex are one letter apart; "650" matches four products.
--   * Imran Qureshi's WhatsApp number changed 6 days ago; the old one is dead.
--   * Ravi Kumar's order volume drops sharply this week ("why is Ravi down").
--   * Duplicate order, off-route order, pending approval, refused approval
--     from a forwarded email, and misbehaving distributor callbacks.
-- =============================================================================

SET search_path = meridian, public;
SELECT set_config('meridian.actor', 'seed', true);

-- ---------------------------------------------------------------------------
-- Areas, regional head, managers, reps (8 areas, 8 managers, 50 reps)
-- 50 reps with "five or six reps each" is impossible for 8 managers (max 48),
-- so North and South Delhi carry 7 reps each; the rest carry 6.
-- ---------------------------------------------------------------------------
INSERT INTO areas (code, name) VALUES
  ('NDL', 'North Delhi'), ('SDL', 'South Delhi'), ('EDL', 'East Delhi'), ('WDL', 'West Delhi'),
  ('GGN', 'Gurugram'),    ('NOI', 'Noida'),       ('FBD', 'Faridabad'),  ('GZB', 'Ghaziabad');

INSERT INTO users (employee_code, full_name, role) VALUES ('RH-NORTH', 'Anjali Mehra', 'regional_head');

INSERT INTO users (employee_code, full_name, role, area_id, reports_to_id)
SELECT 'ASM-' || v.code, v.name, 'area_manager', a.id, (SELECT id FROM users WHERE employee_code = 'RH-NORTH')
FROM (VALUES ('NDL', 'Vikram Malhotra'), ('SDL', 'Pooja Bhatia'), ('EDL', 'Rajesh Tiwari'),
             ('WDL', 'Sunita Arora'),    ('GGN', 'Harish Dahiya'), ('NOI', 'Kavita Srivastava'),
             ('FBD', 'Manoj Rawat'),     ('GZB', 'Seema Tyagi')) AS v(code, name)
JOIN areas a ON a.code = v.code
ORDER BY a.id;

INSERT INTO users (employee_code, full_name, role, area_id, reports_to_id)
SELECT 'REP-' || v.code || '-' || lpad(r.n::text, 2, '0'), r.name, 'rep', a.id, m.id
FROM (VALUES
  ('NDL', ARRAY['Ravi Kumar', 'Imran Qureshi', 'Amit Sharma', 'Nitin Bansal', 'Rohit Khanna', 'Sanjay Gupta', 'Farhan Ali']),
  ('SDL', ARRAY['Priya Nair', 'Sunil Yadav', 'Karan Mehta', 'Deepika Rao', 'Arjun Kapoor', 'Meena Joshi', 'Vivek Anand']),
  ('EDL', ARRAY['Rahul Verma', 'Anil Chauhan', 'Shabnam Khan', 'Gaurav Jain', 'Pankaj Mishra', 'Ritu Saxena']),
  ('WDL', ARRAY['Manish Sethi', 'Tarun Ahuja', 'Neeraj Kohli', 'Simran Kaur', 'Ashok Pal', 'Dinesh Negi']),
  ('GGN', ARRAY['Neha Saini', 'Yogesh Hooda', 'Mohit Yadav', 'Ankit Rathee', 'Pradeep Dalal', 'Komal Sharma']),
  ('NOI', ARRAY['Deepak Chauhan', 'Sachin Tomar', 'Alok Pandey', 'Swati Dubey', 'Varun Singh', 'Nikhil Garg']),
  ('FBD', ARRAY['Lokesh Bhati', 'Jitender Nagar', 'Rakesh Sharma', 'Sonia Malik', 'Hemant Kaushik', 'Vishal Rana']),
  ('GZB', ARRAY['Ajay Tyagi', 'Shivam Goel', 'Ruchi Agarwal', 'Mukesh Chaudhary', 'Abhishek Sisodia', 'Tanvi Mittal'])
) AS v(code, names)
CROSS JOIN LATERAL unnest(v.names) WITH ORDINALITY AS r(name, n)
JOIN areas a ON a.code = v.code
JOIN users m ON m.area_id = a.id AND m.role = 'area_manager'
ORDER BY a.id, r.n;

-- ---------------------------------------------------------------------------
-- Contacts. Fake numbers +91 900000 NNNN (NNNN = user id) and addresses on the
-- reserved .example domain, so nothing here can reach a real person.
-- Reviewers register themselves by adding a row here (see README).
-- ---------------------------------------------------------------------------
INSERT INTO user_contacts (user_id, channel, value, valid_from)
SELECT id, 'whatsapp', '+91900000' || lpad(id::text, 4, '0'), now() - interval '180 days' FROM users
UNION ALL
SELECT id, 'email', lower(replace(full_name, ' ', '.')) || '@meridian.example', now() - interval '180 days' FROM users;

-- Imran's number was dropped 6 days ago and replaced. The old row is closed,
-- not deleted: history survives and the old number no longer resolves.
UPDATE user_contacts
   SET valid_to = now() - interval '6 days', note = 'SIM lost; number retired'
 WHERE channel = 'whatsapp' AND user_id = (SELECT id FROM users WHERE employee_code = 'REP-NDL-02');
INSERT INTO user_contacts (user_id, channel, value, valid_from, note)
SELECT id, 'whatsapp', '+919811042017', now() - interval '6 days', 'replacement number'
  FROM users WHERE employee_code = 'REP-NDL-02';

-- ---------------------------------------------------------------------------
-- Chemists, routes, opening balances
-- 15 chemists across 4 areas, served by 6 reps. Weekdays: 1 = Mon ... 6 = Sat.
-- Amounts below are rupees; multiplied by 100 into paise on insert.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE seed_chemists (code text, name text, locality text, area text, rep text,
                                 weekdays int[], limit_rs numeric, opening_rs numeric) ON COMMIT DROP;
INSERT INTO seed_chemists VALUES
  ('CH-01', 'Sharma Medical Store',    'Model Town',     'NDL', 'REP-NDL-01', '{1,4}',   120000,  45000),
  ('CH-02', 'Gupta Pharmacy',          'Pitampura',      'NDL', 'REP-NDL-01', '{2,5}',    80000,  30000),
  ('CH-03', 'New Life Chemists',       'Shalimar Bagh',  'NDL', 'REP-NDL-01', '{3,6}',   100000, 112500),  -- already over limit
  ('CH-04', 'Jain Medicos',            'Rohini Sec 7',   'NDL', 'REP-NDL-02', '{1,4}',    75000,  52000),
  ('CH-05', 'Kapoor Drug House',       'Civil Lines',    'NDL', 'REP-NDL-02', '{2,5}',   150000,  40000),
  ('CH-06', 'Sharma Medicos',          'Saket',          'SDL', 'REP-SDL-01', '{1,3,5}',  90000,  25000),
  ('CH-07', 'Wellness Point Pharmacy', 'Lajpat Nagar',   'SDL', 'REP-SDL-01', '{2,4,6}', 120000,  60000),
  ('CH-08', 'City Care Chemist',       'Malviya Nagar',  'SDL', 'REP-SDL-02', '{1,3,5}',  70000,  20000),
  ('CH-09', 'Bansal Medical Hall',     'Kalkaji',        'SDL', 'REP-SDL-02', '{2,4,6}', 100000,  35000),
  ('CH-10', 'Singh Medical Agency',    'Sector 18',      'NOI', 'REP-NOI-01', '{1,4}',   200000,  80000),
  ('CH-11', 'Arogya Pharmacy',         'Sector 62',      'NOI', 'REP-NOI-01', '{2,5}',    60000,  15000),
  ('CH-12', 'Om Sai Medicos',          'Sector 50',      'NOI', 'REP-NOI-01', '{3,6}',    50000,  10000),
  ('CH-13', 'Verma Chemists',          'DLF Phase 3',    'GGN', 'REP-GGN-01', '{1,4}',   150000,  55000),
  ('CH-14', 'Lifeline Pharmacy',       'Sohna Road',     'GGN', 'REP-GGN-01', '{2,5}',   100000,  30000),
  ('CH-15', 'Mahajan Medical Store',   'Sector 14',      'GGN', 'REP-GGN-01', '{3,6}',    80000,  20000);

INSERT INTO chemists (code, name, locality, area_id, credit_limit_paise)
SELECT s.code, s.name, s.locality, a.id, (s.limit_rs * 100)::bigint
FROM seed_chemists s JOIN areas a ON a.code = s.area ORDER BY s.code;

INSERT INTO route_stops (rep_id, chemist_id, weekday)
SELECT u.id, c.id, wd
FROM seed_chemists s
JOIN chemists c ON c.code = s.code
JOIN users u ON u.employee_code = s.rep
CROSS JOIN LATERAL unnest(s.weekdays) AS wd;

INSERT INTO credit_ledger (chemist_id, entry_type, amount_paise, occurred_at, note)
SELECT c.id, 'opening_balance', (s.opening_rs * 100)::bigint,
       ((ist_date(now()) - 15) + time '09:00') AT TIME ZONE 'Asia/Kolkata', 'balance brought forward'
FROM seed_chemists s JOIN chemists c ON c.code = s.code;

-- ---------------------------------------------------------------------------
-- Products (40) and price list. Prices are rupees in the literal and become
-- exact integer paise: 32.50 * 100 = 3250 in numeric, no float involved.
-- Deliberately confusable: four "650" products; Merilax vs Merilex.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE seed_products (sku text, name text, pack text, category text, price_rs numeric) ON COMMIT DROP;
INSERT INTO seed_products VALUES
  ('MER-500-15',   'Meridol 500 Tablet',          'strip of 15',      'Pain & Fever',  25.00),
  ('MER-650-10',   'Meridol 650 Tablet',          'strip of 10',      'Pain & Fever',  30.00),
  ('MER-650-15',   'Meridol 650 Tablet',          'strip of 15',      'Pain & Fever',  42.00),
  ('MERP-650-10',  'Meridol-P 650 Tablet',        'strip of 10',      'Pain & Fever',  38.00),
  ('FEB-650-10',   'Febrinil 650 Tablet',         'strip of 10',      'Pain & Fever',  28.50),
  ('MER-SYP-60',   'Meridol Syrup',               '60 ml bottle',     'Pain & Fever',  45.00),
  ('IBU-400-10',   'Ibumer 400 Tablet',           'strip of 10',      'Pain & Fever',  22.00),
  ('IBU-SUS-60',   'Ibumer Suspension',           '60 ml bottle',     'Pain & Fever',  38.00),
  ('CLD-TAB-10',   'Coldmer Tablet',              'strip of 10',      'Cold & Cough',  48.00),
  ('CLDP-TAB-10',  'Coldmer Plus Tablet',         'strip of 10',      'Cold & Cough',  56.00),
  ('KOF-SYP-100',  'Kofset Syrup',                '100 ml bottle',    'Cold & Cough',  95.00),
  ('KOFDX-SYP-100','Kofset DX Syrup',             '100 ml bottle',    'Cold & Cough', 110.00),
  ('NAS-SPR-10',   'Nasomer Nasal Spray',         '10 ml',            'Cold & Cough',  85.00),
  ('MBALM-25',     'Meri Balm',                   '25 g jar',         'Cold & Cough',  60.00),
  ('MLX-SYP-200',  'Merilax Syrup',               '200 ml bottle',    'Digestive',    140.00),
  ('MLE-TAB-10',   'Merilex Tablet',              'strip of 10',      'Allergy',       65.00),
  ('GAS-GEL-170',  'Gasomer Antacid Gel',         '170 ml bottle',    'Digestive',    120.00),
  ('GAS-TAB-10',   'Gasomer Chewable Tablet',     'strip of 10',      'Digestive',     35.00),
  ('ORS-ORG-21',   'Meridian ORS Orange',         '21 g sachet',      'Digestive',     22.00),
  ('ORS-LEM-21',   'Meridian ORS Lemon',          '21 g sachet',      'Digestive',     22.00),
  ('DIG-SYP-200',  'Digimer Enzyme Syrup',        '200 ml bottle',    'Digestive',    150.00),
  ('VITC-500-15',  'Vitamer C 500 Chewable',      'strip of 15',      'Vitamins',      45.00),
  ('VITD-60K-4',   'Vitamer D3 60K Capsule',      'strip of 4',       'Vitamins',     120.00),
  ('VITB-10',      'Vitamer B-Complex Tablet',    'strip of 10',      'Vitamins',      35.00),
  ('CAL-500-15',   'Calcimer 500 Tablet',         'strip of 15',      'Vitamins',     110.00),
  ('ZNC-50-10',    'Zincomer 50 Tablet',          'strip of 10',      'Vitamins',      60.00),
  ('MUL-15',       'Multimer Daily Tablet',       'strip of 15',      'Vitamins',     180.00),
  ('DER-LIQ-100',  'Dermer Antiseptic Liquid',    '100 ml bottle',    'First Aid',     75.00),
  ('DER-LIQ-500',  'Dermer Antiseptic Liquid',    '500 ml bottle',    'First Aid',    280.00),
  ('DER-CRM-30',   'Dermer Antiseptic Cream',     '30 g tube',        'First Aid',     68.00),
  ('MPL-100',      'Meriplast Strips',            'box of 100',       'First Aid',    150.00),
  ('BRN-GEL-20',   'Burnmer Gel',                 '20 g tube',        'First Aid',     85.00),
  ('FNG-PWD-75',   'Fungimer Dusting Powder',     '75 g',             'Skin',         125.00),
  ('PNM-SPR-55',   'Painmer Spray',               '55 g can',         'Pain Relief',  190.00),
  ('PNM-GEL-30',   'Painmer Gel',                 '30 g tube',        'Pain Relief',  110.00),
  ('CET-10-10',    'Cetimer 10 Tablet',           'strip of 10',      'Allergy',       20.00),
  ('CET-SYP-60',   'Cetimer Syrup',               '60 ml bottle',     'Allergy',       55.00),
  ('GLU-500',      'Glucomer Glucose Powder',     '500 g pack',       'Nutrition',    150.00),
  ('SAN-500',      'Merisafe Hand Sanitizer',     '500 ml bottle',    'Hygiene',      250.00),
  ('LOZ-ORG-10',   'Mericough Lozenges Orange',   'pack of 10',       'Cold & Cough',  30.00);

INSERT INTO products (sku, name, pack, category)
SELECT sku, name, pack, category FROM seed_products ORDER BY sku;

INSERT INTO price_list (product_id, unit_price_paise, effective_from)
SELECT p.id, (s.price_rs * 100)::bigint, ist_date(now()) - 180
FROM seed_products s JOIN products p ON p.sku = s.sku;

-- Generic names, only where the data says so (see migration 20260930): Meridol
-- is paracetamol, Ibumer ibuprofen, Cetimer cetirizine. Febrinil 650 and
-- Meridol-P 650 are left without one: nothing here says what they contain.
UPDATE products p SET generic = g.generic
  FROM (VALUES ('MER-500-15', 'paracetamol 500'), ('MER-650-10', 'paracetamol 650'), ('MER-650-15', 'paracetamol 650'),
               ('MER-SYP-60', 'paracetamol syrup'), ('IBU-400-10', 'ibuprofen 400'), ('IBU-SUS-60', 'ibuprofen suspension'),
               ('CET-10-10', 'cetirizine 10'), ('CET-SYP-60', 'cetirizine syrup')) AS g(sku, generic)
 WHERE p.sku = g.sku;

-- Price change inside the history window: Kofset Syrup 95.00 -> 99.00 five
-- days ago. Old orders keep the old price; new ones get the new one.
UPDATE price_list SET effective_to = ist_date(now()) - 5
 WHERE product_id = (SELECT id FROM products WHERE sku = 'KOF-SYP-100');
INSERT INTO price_list (product_id, unit_price_paise, effective_from)
SELECT id, 9900, ist_date(now()) - 5 FROM products WHERE sku = 'KOF-SYP-100';

-- ---------------------------------------------------------------------------
-- Schemes (dates inclusive)
-- ---------------------------------------------------------------------------
INSERT INTO schemes (code, name, product_id, scheme_type, buy_qty, free_qty, discount_bp, starts_on, ends_on)
SELECT v.code, v.name, p.id, v.t, v.buy, v.free, v.bp, ist_date(now()) + v.s, ist_date(now()) + v.e
FROM (VALUES
  ('SCH-MER650',  'Meridol 650 (10s): buy 10 get 1 free', 'MER-650-10',    'buy_x_get_y', 10,   1,    NULL::int, -30, 30),
  ('SCH-ORS-B2G1','ORS Orange: buy 2 get 1 free',         'ORS-ORG-21',    'buy_x_get_y', 2,    1,    NULL,      -10, 20),
  ('SCH-VITC-10', 'Vitamer C: 10% off',                   'VITC-500-15',   'percent_off', NULL, NULL, 1000,      -20, -3),   -- already ended
  ('SCH-KOFDX',   'Kofset DX: buy 5 get 1 free',          'KOFDX-SYP-100', 'buy_x_get_y', 5,    1,    NULL,        1, 30),   -- starts TOMORROW
  ('SCH-CET-5',   'Cetimer 10: 5% off',                   'CET-10-10',     'percent_off', NULL, NULL, 500,       -60, 60)
) AS v(code, name, sku, t, buy, free, bp, s, e)
JOIN products p ON p.sku = v.sku;

-- ---------------------------------------------------------------------------
-- Aliases. rep_id NULL = everyone's name for it; rep_id set = what that rep
-- meant last time (learned after they confirmed a match).
-- ---------------------------------------------------------------------------
INSERT INTO chemist_aliases (chemist_id, alias, rep_id, source)
SELECT c.id, v.alias, u.id, CASE WHEN v.rep IS NULL THEN 'seed' ELSE 'learned' END
FROM (VALUES
  ('CH-01', 'sharma medical',        NULL),
  ('CH-01', 'Sharma Med.',           NULL),
  ('CH-01', 'शर्मा मेडिकल',            NULL),
  ('CH-01', 'sharma medicals',       NULL),
  ('CH-01', 'sharma ji',             'REP-NDL-01'),   -- Ravi's own name for it
  ('CH-02', 'gupta pharma',          NULL),
  ('CH-02', 'गुप्ता फार्मेसी',          NULL),
  ('CH-03', 'newlife',               NULL),
  ('CH-03', 'new life medical',      NULL),
  ('CH-03', 'न्यू लाइफ',               NULL),
  ('CH-06', 'sharma medicos saket',  NULL),
  ('CH-06', 'शर्मा मेडिकोज',            NULL),
  ('CH-06', 'sharma',                'REP-SDL-01'),   -- to Priya, "sharma" means the Saket one
  ('CH-09', 'bansal',                NULL),
  ('CH-09', 'बंसल मेडिकल',             NULL),
  ('CH-10', 'singh medical',         NULL),
  ('CH-10', 'सिंह मेडिकल',             NULL),
  ('CH-12', 'om sai',                NULL),
  ('CH-12', 'ओम साई मेडिकोज',           NULL),
  ('CH-12', 'sai medicos',           NULL)
) AS v(code, alias, rep)
JOIN chemists c ON c.code = v.code
LEFT JOIN users u ON u.employee_code = v.rep;

INSERT INTO product_aliases (product_id, alias, rep_id, source)
SELECT p.id, v.alias, u.id, CASE WHEN v.rep IS NULL THEN 'seed' ELSE 'learned' END
FROM (VALUES
  ('MER-650-10',    'meridol 650',        NULL),          -- ambiguous on purpose: two pack sizes
  ('MER-650-15',    'meridol 650',        NULL),
  ('MER-650-10',    'मेरिडोल 650',          NULL),
  ('MER-650-10',    'pcm 650',            NULL),          -- generic short forms: on BOTH 650 packs
  ('MER-650-15',    'pcm 650',            NULL),
  ('MER-650-10',    'para 650',           NULL),
  ('MER-650-15',    'para 650',           NULL),
  ('MER-650-10',    'पैरासिटामोल 650',     NULL),
  ('MER-650-15',    'पैरासिटामोल 650',     NULL),
  ('MER-500-15',    'pcm 500',            NULL),
  ('MER-500-15',    'para 500',           NULL),
  ('MER-500-15',    'पैरासिटामोल 500',     NULL),
  ('CET-10-10',     'cetrizine 10',       NULL),          -- the common misspelling
  ('MER-650-10',    '650',                'REP-NDL-01'),  -- Ravi's "650" = Meridol 650 (10s)
  ('MERP-650-10',   'meridol p',          NULL),
  ('FEB-650-10',    'febrinil',           NULL),
  ('MLX-SYP-200',   'merilax',            NULL),
  ('MLX-SYP-200',   'मेरिलैक्स',            NULL),
  ('MLX-SYP-200',   'laxative syrup',     NULL),
  ('MLE-TAB-10',    'merilex',            NULL),
  ('MLE-TAB-10',    'मेरिलेक्स',            NULL),
  ('ORS-ORG-21',    'ors orange',         NULL),
  ('ORS-ORG-21',    'ओआरएस ऑरेंज',         NULL),
  ('ORS-LEM-21',    'ors lemon',          NULL),
  ('MPL-100',       'band aid',           NULL),
  ('MPL-100',       'पट्टी',                NULL),
  ('KOFDX-SYP-100', 'kofset dx',          NULL),
  ('KOFDX-SYP-100', 'कफसेट डीएक्स',        NULL),
  ('KOF-SYP-100',   'kofset',             NULL),
  ('CET-10-10',     'cetimer',            NULL),
  ('CET-10-10',     'सेटीमर',              NULL),
  ('VITD-60K-4',    'vit d 60k',          NULL),
  ('SAN-500',       'sanitiser',          NULL),
  ('GAS-GEL-170',   'gasomer',            NULL)
) AS v(sku, alias, rep)
JOIN products p ON p.sku = v.sku
LEFT JOIN users u ON u.employee_code = v.rep;

INSERT INTO audit_log (occurred_at, actor, action, entity_type, entity_id, details)
SELECT now() - interval '9 days', 'user:' || a.rep_id, 'alias.learned', 'chemist_alias', a.id::text,
       jsonb_build_object('alias', a.alias, 'chemist_id', a.chemist_id)
  FROM chemist_aliases a WHERE a.source = 'learned'
UNION ALL
SELECT now() - interval '8 days', 'user:' || a.rep_id, 'alias.learned', 'product_alias', a.id::text,
       jsonb_build_object('alias', a.alias, 'product_id', a.product_id)
  FROM product_aliases a WHERE a.source = 'learned';


-- =============================================================================
-- Order history helpers (temporary: they vanish when this session ends)
-- =============================================================================

-- Moves the seed clock. Every default and trigger reads app_now().
CREATE OR REPLACE FUNCTION pg_temp.at(p_ts timestamptz) RETURNS void
LANGUAGE sql AS $$ SELECT set_config('meridian.now', p_ts::text, true) $$;

-- Creates a draft order with lines. p_lines: explicit '{SKU:qty,...}', or NULL
-- for n pseudo-random lines chosen from p_key.
CREATE OR REPLACE FUNCTION pg_temp.new_order(p_rep_code text, p_chem_code text, p_at timestamptz,
                                  p_key text, p_n int, p_lines text[] DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE v_id bigint;
BEGIN
  PERFORM pg_temp.at(p_at);
  INSERT INTO orders (rep_id, chemist_id, channel, input_type, source_ref)
  SELECT u.id, c.id, 'whatsapp',
         (ARRAY['text', 'text', 'text', 'voice', 'voice', 'photo', 'excel', 'pdf'])[1 + abs(hashtext(p_key || ':in')) % 8],
         'seed:' || p_key
    FROM users u, chemists c
   WHERE u.employee_code = p_rep_code AND c.code = p_chem_code
  RETURNING id INTO v_id;

  -- Only product_id and qty are supplied. Price, scheme, free units and the
  -- line total are filled in by the order_lines_price trigger.
  IF p_lines IS NULL THEN
    INSERT INTO order_lines (order_id, line_no, product_id, qty)
    SELECT v_id, row_number() OVER (ORDER BY md5(p.sku || p_key)), p.id, 5 + abs(hashtext(p.sku || p_key)) % 26
      FROM products p ORDER BY md5(p.sku || p_key) LIMIT p_n;
  ELSE
    INSERT INTO order_lines (order_id, line_no, product_id, qty)
    SELECT v_id, l.n, p.id, split_part(l.item, ':', 2)::int
      FROM unnest(p_lines) WITH ORDINALITY AS l(item, n)
      JOIN products p ON p.sku = split_part(l.item, ':', 1);
  END IF;
  RETURN v_id;
END $$;

-- Rep is shown the summary (which issues a confirmation code) and replies
-- "YES <code>". Goes through the same functions production uses; returns the
-- status confirm_order_by_code chose.
-- The reply is sent from the rep's EMAIL contact: resolve_sender only knows
-- current contacts, and Imran's current WhatsApp number did not exist yet for
-- most of the backdated history. Email addresses have been stable all along.
CREATE OR REPLACE FUNCTION pg_temp.show_and_confirm(p_order bigint, p_t0 timestamptz) RETURNS text
LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE r record; p record; v_email text;
BEGIN
  PERFORM pg_temp.at(p_t0 + interval '2 minutes');
  SELECT * INTO p FROM present_order_for_confirmation((SELECT rep_id FROM orders WHERE id = p_order), p_order);
  SELECT uc.value INTO v_email FROM user_contacts uc JOIN orders o ON o.rep_id = uc.user_id
   WHERE o.id = p_order AND uc.channel = 'email' AND uc.valid_to IS NULL;
  PERFORM pg_temp.at(p_t0 + interval '5 minutes');
  SELECT * INTO r FROM confirm_order_by_code('email', ARRAY[v_email], p.confirmation_code);
  IF r.result NOT IN ('confirmed', 'awaiting_credit_approval') THEN
    RAISE EXCEPTION 'seed: confirmation of order % refused: %', p_order, r.result;
  END IF;
  RETURN r.new_status;
END $$;

-- Rep is shown the summary but has not replied (or replies no).
CREATE OR REPLACE FUNCTION pg_temp.show(p_order bigint, p_at timestamptz) RETURNS bigint
LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE p record;
BEGIN
  PERFORM pg_temp.at(p_at);
  SELECT * INTO p FROM present_order_for_confirmation((SELECT rep_id FROM orders WHERE id = p_order), p_order);
  RETURN p.duplicate_of_order_id;
END $$;

-- The area manager answers the approval email, from their own address.
CREATE OR REPLACE FUNCTION pg_temp.manager_decides(p_order bigint, p_at timestamptz, p_decision text) RETURNS text
LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE v_token text; v_email text;
BEGIN
  SELECT a.token, uc.value INTO v_token, v_email
    FROM credit_approvals a
    JOIN user_contacts uc ON uc.user_id = a.manager_id AND uc.channel = 'email' AND uc.valid_to IS NULL
   WHERE a.order_id = p_order AND a.status = 'pending';
  PERFORM pg_temp.at(p_at);
  RETURN decide_credit_approval(v_token, v_email, p_decision,
           CASE p_decision WHEN 'approved' THEN 'ok approved' ELSE 'No. Collect the pending payment first.' END);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.submit(p_order bigint, p_at timestamptz) RETURNS void
LANGUAGE plpgsql SET search_path = meridian, public AS $$
BEGIN
  PERFORM pg_temp.at(p_at);
  UPDATE orders SET status = 'submitted', submitted_at = p_at,
                    distributor_ref = 'DST-' || lpad(id::text, 6, '0')
   WHERE id = p_order;
END $$;

-- Confirm and submit one of today's scenario orders. Which chemist is on
-- today's route depends on the weekday, and some are over their credit limit by
-- design, so the confirmation may land on awaiting_credit_approval: then the
-- manager approves it first (as in the history), and only then is it submitted.
CREATE OR REPLACE FUNCTION pg_temp.confirm_and_submit(p_order bigint, p_t0 timestamptz, p_sub timestamptz) RETURNS void
LANGUAGE plpgsql SET search_path = meridian, public AS $$
BEGIN
  IF pg_temp.show_and_confirm(p_order, p_t0) = 'awaiting_credit_approval' THEN
    PERFORM pg_temp.manager_decides(p_order, p_sub - interval '1 minute', 'approved');
  END IF;
  PERFORM pg_temp.submit(p_order, p_sub);
END $$;

-- The mock distributor calls back (only for times that are already in the past).
CREATE OR REPLACE FUNCTION pg_temp.callback(p_order bigint, p_status text, p_at timestamptz, p_event_suffix text DEFAULT '')
RETURNS text LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE v_ref text;
BEGIN
  IF p_at > now() THEN RETURN 'not_yet'; END IF;
  SELECT distributor_ref INTO v_ref FROM orders WHERE id = p_order;
  PERFORM pg_temp.at(p_at);
  RETURN record_distributor_event('EVT-' || v_ref || '-' || lower(p_status) || p_event_suffix, v_ref, p_status, p_at,
           jsonb_build_object('ref', v_ref, 'status', p_status, 'at', p_at));
END $$;

-- The rest of an order's life after the rep has been shown the summary:
-- confirmation -> (credit approval) -> submission -> distributor callbacks.
-- p_callbacks picks how the distributor behaves:
--   'normal'       accepted, then dispatched next day
--   'rejected'     distributor rejects it (ledger charge is reversed)
--   'out_of_order' dispatched arrives BEFORE accepted
--   'duplicate'    the dispatched event is delivered twice
--   'unknown'      an 'ON_HOLD' status nobody told us about, then normal
-- p_decision: what the manager says if an approval is needed.
CREATE OR REPLACE FUNCTION pg_temp.complete(p_order bigint, p_t0 timestamptz, p_callbacks text, p_decision text)
RETURNS text LANGUAGE plpgsql SET search_path = meridian, public AS $$
DECLARE
  v_status text;
  v_sub    timestamptz := p_t0 + interval '6 minutes';
  v_acc    timestamptz;
  v_dis    timestamptz;
  v_jitter int := (p_order * 37) % 120;
BEGIN
  v_status := pg_temp.show_and_confirm(p_order, p_t0);
  IF v_status = 'awaiting_credit_approval' THEN
    v_sub := p_t0 + interval '3 hours' + v_jitter * interval '1 minute';
    IF pg_temp.manager_decides(p_order, v_sub, p_decision) = 'rejected' THEN
      RETURN 'credit_rejected';
    END IF;
    v_sub := v_sub + interval '1 minute';
  END IF;

  PERFORM pg_temp.submit(p_order, v_sub);
  v_acc := v_sub + interval '90 minutes' + v_jitter * interval '1 minute';
  v_dis := ((ist_date(p_t0) + 1 + time '11:00') AT TIME ZONE 'Asia/Kolkata') + v_jitter * interval '1 minute';

  CASE p_callbacks
    WHEN 'rejected' THEN
      PERFORM pg_temp.callback(p_order, 'REJECTED', v_acc);
    WHEN 'out_of_order' THEN
      PERFORM pg_temp.callback(p_order, 'DISPATCHED', v_dis);
      PERFORM pg_temp.callback(p_order, 'ACCEPTED', v_dis + interval '5 minutes');
    WHEN 'duplicate' THEN
      PERFORM pg_temp.callback(p_order, 'ACCEPTED', v_acc);
      PERFORM pg_temp.callback(p_order, 'DISPATCHED', v_dis);
      PERFORM pg_temp.callback(p_order, 'DISPATCHED', v_dis + interval '2 minutes');  -- same event id again
    WHEN 'unknown' THEN
      PERFORM pg_temp.callback(p_order, 'ON_HOLD', v_acc);
      PERFORM pg_temp.callback(p_order, 'ACCEPTED', v_acc + interval '40 minutes');
      PERFORM pg_temp.callback(p_order, 'DISPATCHED', v_dis);
    ELSE
      PERFORM pg_temp.callback(p_order, 'ACCEPTED', v_acc);
      PERFORM pg_temp.callback(p_order, 'DISPATCHED', v_dis);
  END CASE;
  RETURN (SELECT status FROM orders WHERE id = p_order);
END $$;

-- A rep's chemist that IS on the route for a given date (first by code), or
-- NULL if they have none that day.
CREATE OR REPLACE FUNCTION pg_temp.on_route_chemist(p_rep_code text, p_date date) RETURNS text
LANGUAGE sql SET search_path = meridian, public AS $$
  SELECT c.code FROM route_stops rs JOIN chemists c ON c.id = rs.chemist_id
  JOIN users u ON u.id = rs.rep_id
  WHERE u.employee_code = p_rep_code AND rs.weekday = extract(isodow FROM p_date)
  ORDER BY c.code LIMIT 1
$$;

-- Most recent date in [p_from, p_to] on which a chemist is on its rep's route.
CREATE OR REPLACE FUNCTION pg_temp.last_route_day(p_chem_code text, p_from date, p_to date) RETURNS date
LANGUAGE sql SET search_path = meridian, public AS $$
  SELECT max(d::date) FROM generate_series(p_from, p_to, interval '1 day') AS d
  WHERE extract(isodow FROM d) IN (SELECT rs.weekday FROM route_stops rs JOIN chemists c ON c.id = rs.chemist_id
                                    WHERE c.code = p_chem_code)
$$;


-- =============================================================================
-- Two weeks of history
-- =============================================================================
DO $history$
DECLARE
  v_today  date := ist_date(now());
  d        date;
  st       record;
  h        bigint;
  v_prob   int;
  v_t0     timestamptz;
  v_order  bigint;
  v_n_appr int;
  v_sent   int := 0;
  pay      record;
BEGIN
  FOR d IN SELECT generate_series(v_today - 14, v_today - 1, interval '1 day')::date LOOP
    CONTINUE WHEN extract(isodow FROM d) = 7;   -- no Sunday trade

    FOR st IN
      SELECT DISTINCT u.employee_code AS rep, c.code AS chem,
             EXISTS (SELECT 1 FROM route_stops x WHERE x.rep_id = rs.rep_id AND x.chemist_id = rs.chemist_id
                       AND x.weekday = extract(isodow FROM d)) AS on_route
        FROM route_stops rs JOIN users u ON u.id = rs.rep_id JOIN chemists c ON c.id = rs.chemist_id
       ORDER BY 2
    LOOP
      h := abs(hashtext(st.chem || '|' || d));
      v_prob := CASE
                  WHEN NOT st.on_route THEN 6                                  -- occasional off-route order
                  WHEN st.rep = 'REP-NDL-01' AND d >= v_today - 7 THEN 25      -- Ravi's slump this week
                  ELSE 85 END;
      CONTINUE WHEN h % 100 >= v_prob;

      v_t0 := ((d + time '10:00') AT TIME ZONE 'Asia/Kolkata') + ((h / 100) % 480) * interval '1 minute';
      v_order := pg_temp.new_order(st.rep, st.chem, v_t0, st.chem || '|' || d, (2 + (h / 7) % 4)::int);

      -- About 1 in 20: rep looks at the summary and says no.
      IF (h / 13) % 20 = 0 THEN
        PERFORM pg_temp.show(v_order, v_t0 + interval '2 minutes');
        PERFORM pg_temp.at(v_t0 + interval '6 minutes');
        UPDATE orders SET status = 'cancelled' WHERE id = v_order;
        CONTINUE;
      END IF;

      -- If this chemist needs approvals, every 2nd request is refused.
      SELECT count(*) INTO v_n_appr FROM credit_approvals a JOIN orders o ON o.id = a.order_id
       WHERE o.chemist_id = (SELECT chemist_id FROM orders WHERE id = v_order);
      -- Distributor misbehaviour on a fixed rotation, so every case is present.
      v_sent := v_sent + 1;
      PERFORM pg_temp.complete(v_order, v_t0,
        CASE v_sent % 12 WHEN 2 THEN 'rejected' WHEN 5 THEN 'out_of_order' WHEN 8 THEN 'duplicate'
                         WHEN 11 THEN 'unknown' ELSE 'normal' END,
        CASE WHEN v_n_appr % 2 = 1 THEN 'rejected' ELSE 'approved' END);
    END LOOP;

    -- Saturday evening: chemists pay about 40% of what they owe, rounded down
    -- to the nearest 1,000 rupees. New Life and Jain pay nothing (stay tight).
    IF extract(isodow FROM d) = 6 THEN
      PERFORM pg_temp.at((d + time '18:00') AT TIME ZONE 'Asia/Kolkata');
      FOR pay IN
        SELECT chemist_id, (owed_paise * 4 / 10) / 100000 * 100000 AS amt
          FROM v_chemist_credit WHERE code NOT IN ('CH-03', 'CH-04')
      LOOP
        CONTINUE WHEN pay.amt <= 0;
        INSERT INTO credit_ledger (chemist_id, entry_type, amount_paise, note)
        VALUES (pay.chemist_id, 'payment', -pay.amt, 'weekly collection');
      END LOOP;
    END IF;
  END LOOP;

  -- Two history orders that must exist regardless of the pseudo-random draw.
  -- (a) Imran -> Kapoor Drug House bought Kofset Syrup BEFORE its price rose,
  --     so that line is priced at the old 95.00.
  d := pg_temp.last_route_day('CH-05', v_today - 13, v_today - 6);
  v_t0 := (d + time '12:15') AT TIME ZONE 'Asia/Kolkata';
  v_order := pg_temp.new_order('REP-NDL-02', 'CH-05', v_t0, 'hist-kofset', NULL, '{KOF-SYP-100:24,CLD-TAB-10:10}');
  PERFORM pg_temp.complete(v_order, v_t0, 'normal', 'approved');

  -- (b) Ravi -> New Life Chemists this week: over the limit, and Vikram said no.
  --     Part of the answer to "why is Ravi down this week".
  d := pg_temp.last_route_day('CH-03', v_today - 6, v_today - 1);
  v_t0 := (d + time '11:40') AT TIME ZONE 'Asia/Kolkata';
  v_order := pg_temp.new_order('REP-NDL-01', 'CH-03', v_t0, 'hist-newlife', NULL, '{MUL-15:20,CAL-500-15:15,VITD-60K-4:10}');
  IF pg_temp.complete(v_order, v_t0, 'normal', 'rejected') <> 'credit_rejected' THEN
    RAISE EXCEPTION 'seed expected the New Life order to be refused on credit';
  END IF;

  -- Reps were told about every applied history callback a minute after it arrived.
  UPDATE distributor_events SET rep_notified_at = received_at + interval '1 minute' WHERE result = 'applied';
END $history$;


-- =============================================================================
-- Today: orders in every interesting state. Each rep uses a chemist that is on
-- TODAY's route unless noted, so the off-route flag means something.
-- =============================================================================
DO $today$
DECLARE
  v_today    date := ist_date(now());
  v_base     timestamptz;
  v_order    bigint;
  v_a        bigint;
  v_b        bigint;
  v_headroom bigint;
  v_qty      int;
  v_chem     text;
  v_status   text;
BEGIN
  -- Anchor today's activity a few hours back, but never before today's date in India.
  v_base := greatest((v_today + time '09:30') AT TIME ZONE 'Asia/Kolkata', now() - interval '4 hours');

  -- 1. Ravi, on-route chemist: confirmed and submitted, no callback yet.
  --    Meridol 650 (10s) x 20 gets 2 free under SCH-MER650.
  v_order := pg_temp.new_order('REP-NDL-01', coalesce(pg_temp.on_route_chemist('REP-NDL-01', v_today), 'CH-01'),
                               v_base, 'today-1', NULL, '{MER-650-10:20,MLX-SYP-200:6,ORS-ORG-21:10}');
  PERFORM pg_temp.confirm_and_submit(v_order, v_base, v_base + interval '6 minutes');

  -- 2. Imran -> Jain Medicos (tight credit by design; may be off route today,
  --    which is allowed). Sized to break the limit, so it waits for Vikram.
  --    Includes Kofset DX, whose scheme starts TOMORROW: no free units today.
  SELECT headroom_paise INTO v_headroom FROM v_chemist_credit WHERE code = 'CH-04';
  v_qty := greatest(v_headroom / 28000 + 10, 10);
  v_order := pg_temp.new_order('REP-NDL-02', 'CH-04', v_base + interval '20 minutes', 'today-2', NULL,
                               ARRAY['DER-LIQ-500:' || v_qty, 'KOFDX-SYP-100:10']);
  v_status := pg_temp.show_and_confirm(v_order, v_base + interval '20 minutes');
  IF v_status <> 'awaiting_credit_approval' THEN
    RAISE EXCEPTION 'seed expected Jain Medicos order to need approval, got %', v_status;
  END IF;
  UPDATE credit_approvals SET email_message_id = '<' || token || '@meridian.example>' WHERE order_id = v_order;
  -- Vikram forwarded the email to Pooja (ASM South Delhi), who replied "approved".
  -- She is not the approver on record: refused, logged, still pending.
  PERFORM pg_temp.at(v_base + interval '50 minutes');
  PERFORM decide_credit_approval((SELECT token FROM credit_approvals WHERE order_id = v_order),
                                 'pooja.bhatia@meridian.example', 'approved', 'approved - Pooja (fwd from Vikram)');

  -- 3 + 4. Sunil, on-route chemist: the same order sent twice, 5 minutes apart.
  v_chem := coalesce(pg_temp.on_route_chemist('REP-SDL-02', v_today), 'CH-08');
  v_a := pg_temp.new_order('REP-SDL-02', v_chem, v_base + interval '30 minutes', 'today-3', NULL,
                           '{GAS-GEL-170:12,CET-10-10:20,DER-CRM-30:8}');
  PERFORM pg_temp.confirm_and_submit(v_a, v_base + interval '30 minutes', v_base + interval '36 minutes');

  v_b := pg_temp.new_order('REP-SDL-02', v_chem, v_base + interval '35 minutes', 'today-4', NULL,
                           '{DER-CRM-30:8,GAS-GEL-170:12,CET-10-10:20}');   -- same lines, typed in another order
  IF pg_temp.show(v_b, v_base + interval '36 minutes') IS DISTINCT FROM v_a THEN
    RAISE EXCEPTION 'seed expected order % to be flagged as a duplicate of %', v_b, v_a;
  END IF;

  -- 5. Priya: deliberately an order for one of her chemists NOT on today's route.
  SELECT c.code INTO v_chem
    FROM chemists c JOIN route_stops rs ON rs.chemist_id = c.id
    JOIN users u ON u.id = rs.rep_id AND u.employee_code = 'REP-SDL-01'
   GROUP BY c.code
  HAVING NOT bool_or(rs.weekday = extract(isodow FROM v_today))
   ORDER BY c.code LIMIT 1;
  v_order := pg_temp.new_order('REP-SDL-01', v_chem, v_base + interval '45 minutes', 'today-5', NULL,
                               '{VITC-500-15:15,ZNC-50-10:10,MUL-15:5}');
  PERFORM pg_temp.confirm_and_submit(v_order, v_base + interval '45 minutes', v_base + interval '51 minutes');

  -- 6. Neha, on-route chemist: summary shown, rep has not said yes yet.
  --    Every scheme case on one summary.
  v_order := pg_temp.new_order('REP-GGN-01', coalesce(pg_temp.on_route_chemist('REP-GGN-01', v_today), 'CH-13'),
                               v_base + interval '55 minutes', 'today-6', NULL,
                               '{MER-650-10:30,CET-10-10:10,KOFDX-SYP-100:12,ORS-ORG-21:9,MLE-TAB-10:4}');
  PERFORM pg_temp.show(v_order, v_base + interval '57 minutes');

  -- 7. Deepak, on-route chemist: still being built.
  v_order := pg_temp.new_order('REP-NOI-01', coalesce(pg_temp.on_route_chemist('REP-NOI-01', v_today), 'CH-10'),
                               v_base + interval '60 minutes', 'today-7', NULL, '{PNM-SPR-55:6,SAN-500:4}');

  -- A callback for an order we never sent.
  PERFORM pg_temp.at(v_base + interval '70 minutes');
  PERFORM record_distributor_event('EVT-GHOST-0001', 'DST-999999', 'DISPATCHED', v_base + interval '70 minutes',
                                   '{"ref": "DST-999999", "status": "DISPATCHED"}');

  -- Identity: messages from numbers that resolve to nobody. The first is
  -- Imran's OLD number, two days after it was retired.
  INSERT INTO audit_log (occurred_at, actor, action, details)
  SELECT now() - interval '4 days', 'unknown:' || uc.value, 'identity.unknown_sender',
         '{"channel": "whatsapp", "reply": "generic refusal, no Meridian data"}'::jsonb
    FROM user_contacts uc JOIN users u ON u.id = uc.user_id
   WHERE u.employee_code = 'REP-NDL-02' AND uc.channel = 'whatsapp' AND uc.valid_to IS NOT NULL
  UNION ALL
  SELECT now() - interval '1 day', 'unknown:+919999912345', 'identity.unknown_sender',
         '{"channel": "whatsapp", "reply": "generic refusal, no Meridian data"}'::jsonb;
END $today$;

SELECT set_config('meridian.now', '', true);

-- The history above raised and decided approvals, which queued real
-- notifications. Seed data is never delivered: mark them suppressed so the
-- dispatcher does not email the reserved .example addresses or fake numbers.
UPDATE notification_outbox SET status = 'suppressed', last_error = 'seed data: never delivered'
 WHERE status = 'pending';
-- Likewise, nothing the seed confirmed is ever sent to the distributor.
UPDATE distributor_submissions SET status = 'suppressed', last_error = 'seed data: never sent'
 WHERE status = 'pending';

-- Neon's pooled endpoint keeps server sessions alive between clients, so temp
-- functions would outlive this run. Drop them explicitly.
DROP FUNCTION pg_temp.at(timestamptz), pg_temp.new_order(text, text, timestamptz, text, int, text[]),
              pg_temp.show_and_confirm(bigint, timestamptz), pg_temp.show(bigint, timestamptz),
              pg_temp.manager_decides(bigint, timestamptz, text),
              pg_temp.submit(bigint, timestamptz), pg_temp.confirm_and_submit(bigint, timestamptz, timestamptz),
              pg_temp.callback(bigint, text, timestamptz, text),
              pg_temp.complete(bigint, timestamptz, text, text), pg_temp.on_route_chemist(text, date),
              pg_temp.last_route_day(text, date, date);
