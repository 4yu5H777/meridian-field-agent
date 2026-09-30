-- =============================================================================
-- 2026-09-30: generic (active ingredient) names for products.
-- Live finding: a rep typed "paracetamol 650" and nothing matched, because the
-- catalogue knew only its own brand names (Meridol). Products now carry their
-- generic name, the matcher also compares against it, and the common short
-- forms (pcm, para) and the Hindi spelling are aliases. A generic shared by
-- several products (both Meridol 650 packs) scores the same for each, so the
-- rep is ASKED which one: nothing is guessed, and thresholds are unchanged.
--
-- Generics are only assigned where the data itself says so: Meridol is
-- paracetamol (the seed's "pcm 650" alias), Ibumer ibuprofen, Cetimer
-- cetirizine. Febrinil 650 and Meridol-P 650 are left out: the data does not
-- say what they contain (Meridol-P reads as a combination product).
-- Competitor brands ("Dolo 650") are deliberately NOT mapped.
--
-- Idempotent; applied to the live database without a reset (keeps reviewer
-- registrations and live orders). schema.sql and seed.sql carry the same, so
-- a reset gives the same result.
--   node --env-file=.env.owner scripts/db.mjs db/migrations/20260930_generic_names.sql
-- =============================================================================
BEGIN;
SET ROLE meridian_owner;
SET search_path = meridian, public;

ALTER TABLE products ADD COLUMN IF NOT EXISTS generic text;
ALTER TABLE products ADD COLUMN IF NOT EXISTS generic_norm text GENERATED ALWAYS AS (normalize_name(generic)) STORED;
CREATE INDEX IF NOT EXISTS products_generic_trgm ON products USING gin (generic_norm gin_trgm_ops);

CREATE OR REPLACE FUNCTION match_product(p_rep_id bigint, p_text text)
RETURNS TABLE (product_id bigint, product_name text, matched_on text, score real, is_rep_alias boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  WITH q AS (SELECT normalize_name(p_text) AS t),
  hits AS (
    SELECT p.id, p.name AS matched, similarity(p.name_norm, q.t) AS s, false AS rep_alias
      FROM products p, q
     WHERE p.is_active AND (p.name_norm % q.t OR p.name_norm = q.t)
    UNION ALL
    -- The generic name ("paracetamol 650"): shared by every product with that
    -- ingredient and strength, so an exact hit on it is ambiguous by design.
    SELECT p.id, p.generic, CASE WHEN p.generic_norm = q.t THEN 1.0 ELSE similarity(p.generic_norm, q.t) END, false
      FROM products p, q
     WHERE p.is_active AND p.generic_norm IS NOT NULL AND (p.generic_norm % q.t OR p.generic_norm = q.t)
    UNION ALL
    SELECT a.product_id, a.alias,
           CASE WHEN a.alias_norm = q.t THEN 1.0 ELSE similarity(a.alias_norm, q.t) END,
           a.rep_id IS NOT NULL
      FROM product_aliases a, q
     WHERE (a.rep_id IS NULL OR a.rep_id = p_rep_id)
       AND (a.alias_norm % q.t OR a.alias_norm = q.t)
  )
  SELECT best.* FROM (
    SELECT DISTINCT ON (h.id) h.id, p.name, h.matched, h.s::real AS s, h.rep_alias
      FROM hits h JOIN products p ON p.id = h.id
     ORDER BY h.id, h.s DESC, h.rep_alias DESC   -- best hit per product
  ) best
  ORDER BY best.s DESC, best.rep_alias DESC;      -- best score first; on a tie the rep's own alias wins
END;

UPDATE products p SET generic = g.generic
  FROM (VALUES ('MER-500-15', 'paracetamol 500'), ('MER-650-10', 'paracetamol 650'), ('MER-650-15', 'paracetamol 650'),
               ('MER-SYP-60', 'paracetamol syrup'), ('IBU-400-10', 'ibuprofen 400'), ('IBU-SUS-60', 'ibuprofen suspension'),
               ('CET-10-10', 'cetirizine 10'), ('CET-SYP-60', 'cetirizine syrup')) AS g(sku, generic)
 WHERE p.sku = g.sku AND p.generic IS DISTINCT FROM g.generic;

-- Short forms and the Hindi spelling, on EVERY product with that generic.
INSERT INTO product_aliases (product_id, alias, rep_id, source)
SELECT p.id, v.alias, NULL, 'seed'
  FROM (VALUES ('MER-650-10', 'pcm 650'), ('MER-650-15', 'pcm 650'),
               ('MER-650-10', 'para 650'), ('MER-650-15', 'para 650'),
               ('MER-650-10', 'पैरासिटामोल 650'), ('MER-650-15', 'पैरासिटामोल 650'),
               ('MER-500-15', 'pcm 500'), ('MER-500-15', 'para 500'), ('MER-500-15', 'पैरासिटामोल 500'),
               ('CET-10-10', 'cetrizine 10')) AS v(sku, alias)          -- the common misspelling
  JOIN products p ON p.sku = v.sku
ON CONFLICT DO NOTHING;

RESET ROLE;
COMMIT;
