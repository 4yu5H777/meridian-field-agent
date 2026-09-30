-- =============================================================================
-- Meridian Healthcare: system of record (Assignment B, section 06)
--
-- Re-runnable: drops and recreates the `meridian` schema. Nothing outside that
-- schema is touched except the two extensions below.
--
-- Conventions used throughout:
--   * Money is bigint paise (1 rupee = 100 paise). Never float, never numeric
--     typed by a person. Integer arithmetic means totals are exact and repeatable.
--   * Status / type columns are text + CHECK rather than enum types: easier to
--     evolve, and the allowed values are visible right next to the column.
--   * Business rules that must never be "talked around" (price, credit,
--     confirmation, state transitions) are enforced here in triggers, so they
--     hold no matter which code path, tool, or model issued the SQL.
--   * Every trigger error message starts with 'GUARD:' so application code can
--     recognise a rule violation and explain it instead of crashing.
--   * Dates are business dates in Asia/Kolkata.
--   * Every object is owned by meridian_owner (see roles.sql). Runtime roles
--     get no table writes at all; they call the functions in section 11, and
--     privileges.sql decides which role may call which function.
--   * plpgsql functions pin search_path to "meridian, public, pg_temp". pg_temp
--     LAST matters: when it is not listed Postgres searches it FIRST, so a
--     caller could create a temp table named price_list and have the pricing
--     trigger read it instead of the real one.
--
-- Run order (npm run db:reset): roles.sql, schema.sql, seed.sql, privileges.sql
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- trigram similarity for fuzzy name matching
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- lets GiST exclusion constraints mix = on ids with && on ranges

DROP SCHEMA IF EXISTS meridian CASCADE;
-- Everything from here on is created by, and therefore owned by, meridian_owner.
SET ROLE meridian_owner;
CREATE SCHEMA meridian;
SET search_path = meridian, public;


-- -----------------------------------------------------------------------------
-- Small helpers
-- -----------------------------------------------------------------------------

-- The clock every default and trigger uses. In normal operation it is now().
-- The seed script sets `meridian.now` (transaction-local) so it can backfill two
-- weeks of history with realistic timestamps through the SAME triggers and
-- functions production uses, instead of bypassing them.
-- Any session can set a custom setting like meridian.now, so the override is
-- honoured only when the LOGIN (session_user) belongs to meridian_owner, i.e.
-- the migration/seed login. session_user, not current_user: inside a SECURITY
-- DEFINER function current_user is the owner for every caller.
CREATE FUNCTION app_now() RETURNS timestamptz
LANGUAGE sql STABLE
RETURN CASE WHEN pg_has_role(session_user, 'meridian_owner', 'MEMBER')
            THEN coalesce(nullif(current_setting('meridian.now', true), '')::timestamptz, now())
            ELSE now() END;

-- Business date in India for a timestamp.
CREATE FUNCTION ist_date(ts timestamptz) RETURNS date
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN (ts AT TIME ZONE 'Asia/Kolkata')::date;

-- Display only: paise -> rupees as an exact 2-decimal numeric (no float).
CREATE FUNCTION rupees(p_paise bigint) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN round(p_paise / 100.0, 2);

-- Normalises a chemist/product name or alias for matching: lower case, common
-- punctuation to spaces, whitespace collapsed. Deliberately does NOT strip
-- non-ASCII characters, so Devanagari (including vowel signs) survives intact.
CREATE FUNCTION normalize_name(t text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN btrim(regexp_replace(regexp_replace(lower(t), '[.,''"()/&_-]+', ' ', 'g'), '\s+', ' ', 'g'));

-- Blocks UPDATE, DELETE and TRUNCATE on append-only tables (audit, ledger,
-- history). Corrections are made by appending a new row, never by rewriting an
-- old one. Used as a row trigger for UPDATE/DELETE and a statement trigger for
-- TRUNCATE, so it holds even for the owner.
CREATE FUNCTION forbid_update_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'GUARD: % is append-only (% not allowed)', TG_TABLE_NAME, TG_OP;
END $$;


-- =============================================================================
-- 1. Organisation and identity
-- =============================================================================

CREATE TABLE areas (
  id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code  text NOT NULL UNIQUE,               -- 'NDL'
  name  text NOT NULL UNIQUE                -- 'North Delhi'
);

-- One table for every person who can talk to the agent. Role decides visibility.
-- reports_to_id encodes the hierarchy: rep -> area manager -> regional head.
CREATE TABLE users (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_code  text NOT NULL UNIQUE,      -- 'REP-NDL-01', 'ASM-NDL', 'RH-NORTH'
  full_name      text NOT NULL,
  role           text NOT NULL CHECK (role IN ('rep', 'area_manager', 'regional_head')),
  area_id        bigint REFERENCES areas(id),
  reports_to_id  bigint REFERENCES users(id),
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT app_now(),
  CONSTRAINT users_role_shape CHECK (
       (role = 'regional_head' AND area_id IS NULL AND reports_to_id IS NULL)
    OR (role IN ('rep', 'area_manager') AND area_id IS NOT NULL AND reports_to_id IS NOT NULL)
  )
);
CREATE INDEX users_reports_to_idx ON users (reports_to_id);
CREATE INDEX users_area_idx ON users (area_id);
CREATE UNIQUE INDEX users_one_manager_per_area ON users (area_id) WHERE role = 'area_manager';

-- "A manager sees their own reps" is only safe if reports_to_id is right, so the
-- hierarchy is validated: a rep reports to the manager of the SAME area, and a
-- manager reports to the regional head.
CREATE FUNCTION users_check_hierarchy() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
DECLARE boss users;
BEGIN
  IF NEW.reports_to_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO boss FROM users WHERE id = NEW.reports_to_id;
  IF NEW.role = 'rep' AND NOT (boss.role = 'area_manager' AND boss.area_id = NEW.area_id) THEN
    RAISE EXCEPTION 'GUARD: rep % must report to the area manager of their own area', NEW.employee_code;
  END IF;
  IF NEW.role = 'area_manager' AND boss.role <> 'regional_head' THEN
    RAISE EXCEPTION 'GUARD: area manager % must report to the regional head', NEW.employee_code;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER users_check_hierarchy BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION users_check_hierarchy();

-- How we recognise a sender. Phone numbers and emails are separate rows with a
-- validity window, so a number can be retired (valid_to set) without losing
-- history, and the old number immediately stops resolving to anyone.
CREATE TABLE user_contacts (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     bigint NOT NULL REFERENCES users(id),
  channel     text NOT NULL CHECK (channel IN ('whatsapp', 'email')),
  value       text NOT NULL,
  valid_from  timestamptz NOT NULL DEFAULT app_now(),
  valid_to    timestamptz,                   -- NULL = current
  note        text,
  CHECK (valid_to IS NULL OR valid_to > valid_from),
  -- Stored already normalised, so lookups are a plain equality on an index.
  CHECK (
       (channel = 'whatsapp' AND value ~ '^\+[1-9][0-9]{7,14}$')              -- E.164
    OR (channel = 'email' AND value = lower(btrim(value)) AND value ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
  )
);
-- A number/email can have at most ONE current owner. This is both the identity
-- lookup index and the guarantee that a message cannot resolve to two people.
CREATE UNIQUE INDEX user_contacts_one_current_owner ON user_contacts (channel, value) WHERE valid_to IS NULL;
CREATE INDEX user_contacts_user_idx ON user_contacts (user_id);

-- Normalises what a channel hands us into the stored form.
CREATE FUNCTION normalize_contact(p_channel text, p_value text) RETURNS text
LANGUAGE sql IMMUTABLE
RETURN CASE p_channel
  WHEN 'email' THEN lower(btrim(p_value))
  WHEN 'whatsapp' THEN '+' || regexp_replace(p_value, '[^0-9]', '', 'g')
END;

-- Identity: returns exactly one row for a known, active, current contact, and
-- zero rows otherwise. Zero rows means the caller must return nothing from
-- Meridian's data. This runs before the model ever sees the message.
-- SECURITY DEFINER: callers (meridian_system) need no access to user_contacts.
CREATE FUNCTION resolve_sender(p_channel text, p_value text)
RETURNS TABLE (user_id bigint, full_name text, role text, area_id bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  SELECT u.id, u.full_name, u.role, u.area_id
  FROM user_contacts c
  JOIN users u ON u.id = c.user_id
  WHERE c.channel = p_channel
    AND c.value = normalize_contact(p_channel, p_value)
    AND c.valid_to IS NULL
    AND c.valid_from <= app_now()
    AND u.is_active;
END;

-- Visibility: which reps' data a viewer may see. Every reporting query filters
-- on this. Rep: self. Manager: reps reporting to them. Regional head: all reps.
-- ROWS 10: tells the planner a manager sees ~6 reps (default guess is 1000),
-- so it probes orders(rep_id, created_at) per rep instead of scanning by date.
CREATE FUNCTION visible_rep_ids(p_viewer_id bigint) RETURNS SETOF bigint
LANGUAGE sql STABLE ROWS 10 SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  SELECT r.id
  FROM users r
  JOIN users v ON v.id = p_viewer_id AND v.is_active
  WHERE r.role = 'rep'
    AND (   (v.role = 'rep'           AND r.id = v.id)
         OR (v.role = 'area_manager'  AND r.reports_to_id = v.id)
         OR (v.role = 'regional_head'));
END;


-- =============================================================================
-- 2. Chemists, routes, aliases
-- =============================================================================

CREATE TABLE chemists (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code                text NOT NULL UNIQUE,  -- 'CH-01'
  name                text NOT NULL,
  locality            text NOT NULL,
  area_id             bigint NOT NULL REFERENCES areas(id),
  credit_limit_paise  bigint NOT NULL CHECK (credit_limit_paise >= 0),
  is_active           boolean NOT NULL DEFAULT true,
  name_norm           text GENERATED ALWAYS AS (normalize_name(name)) STORED
);
CREATE INDEX chemists_area_idx ON chemists (area_id);
CREATE INDEX chemists_name_trgm ON chemists USING gin (name_norm gin_trgm_ops);

-- The fixed weekly route. A chemist is "a rep's chemist" if it is on that rep's
-- route on any weekday; "on today's route" if it is on it for today's weekday.
-- weekday is ISO: 1 = Monday ... 6 = Saturday (no Sunday routes).
CREATE TABLE route_stops (
  rep_id      bigint NOT NULL REFERENCES users(id),
  chemist_id  bigint NOT NULL REFERENCES chemists(id),
  weekday     smallint NOT NULL CHECK (weekday BETWEEN 1 AND 6),
  PRIMARY KEY (rep_id, chemist_id, weekday),
  -- Each chemist is served by exactly one rep (assumption, see README):
  -- two stops for the same chemist with DIFFERENT reps are rejected.
  EXCLUDE USING gist (chemist_id WITH =, rep_id WITH <>)
);
CREATE INDEX route_stops_chemist_idx ON route_stops (chemist_id);

CREATE FUNCTION route_stops_check() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users u JOIN chemists c ON c.id = NEW.chemist_id
                 WHERE u.id = NEW.rep_id AND u.role = 'rep' AND u.area_id = c.area_id) THEN
    RAISE EXCEPTION 'GUARD: route stop must pair a rep with a chemist in the rep''s own area';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER route_stops_check BEFORE INSERT OR UPDATE ON route_stops
  FOR EACH ROW EXECUTE FUNCTION route_stops_check();

-- Other names for a chemist: spellings, abbreviations, Hindi script.
-- rep_id NULL  = everyone uses this name.
-- rep_id set   = what THIS rep meant last time ("sharma ji" for Ravi), learned
--                after the rep confirmed a match. Rep-specific beats global.
CREATE TABLE chemist_aliases (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  chemist_id  bigint NOT NULL REFERENCES chemists(id),
  alias       text NOT NULL,
  alias_norm  text GENERATED ALWAYS AS (normalize_name(alias)) STORED,
  rep_id      bigint REFERENCES users(id),
  source      text NOT NULL DEFAULT 'seed' CHECK (source IN ('seed', 'learned')),
  created_at  timestamptz NOT NULL DEFAULT app_now(),
  UNIQUE NULLS NOT DISTINCT (chemist_id, alias_norm, rep_id)
);
-- For one rep, one alias means one chemist (no ambiguity in what we learned).
CREATE UNIQUE INDEX chemist_aliases_rep_unique ON chemist_aliases (rep_id, alias_norm) WHERE rep_id IS NOT NULL;
CREATE INDEX chemist_aliases_trgm ON chemist_aliases USING gin (alias_norm gin_trgm_ops);
CREATE INDEX chemist_aliases_chemist_idx ON chemist_aliases (chemist_id);

-- Candidate chemists for free text, searched ONLY among the rep's own chemists.
-- Returns ranked candidates; the agent picks or asks. It never invents one.
CREATE FUNCTION match_chemist(p_rep_id bigint, p_text text)
RETURNS TABLE (chemist_id bigint, chemist_name text, matched_on text, score real, is_rep_alias boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  WITH q AS (SELECT normalize_name(p_text) AS t),
  mine AS (SELECT DISTINCT rs.chemist_id FROM route_stops rs WHERE rs.rep_id = p_rep_id),
  hits AS (
    SELECT c.id, c.name AS matched, similarity(c.name_norm, q.t) AS s, false AS rep_alias
      FROM chemists c, q
     WHERE c.id IN (SELECT m.chemist_id FROM mine m) AND (c.name_norm % q.t OR c.name_norm = q.t)
    UNION ALL
    SELECT a.chemist_id, a.alias,
           CASE WHEN a.alias_norm = q.t THEN 1.0 ELSE similarity(a.alias_norm, q.t) END,
           a.rep_id IS NOT NULL
      FROM chemist_aliases a, q
     WHERE a.chemist_id IN (SELECT m.chemist_id FROM mine m)
       AND (a.rep_id IS NULL OR a.rep_id = p_rep_id)
       AND (a.alias_norm % q.t OR a.alias_norm = q.t)
  )
  SELECT best.* FROM (
    SELECT DISTINCT ON (h.id) h.id, c.name, h.matched, h.s::real AS s, h.rep_alias
      FROM hits h JOIN chemists c ON c.id = h.id
     ORDER BY h.id, h.s DESC, h.rep_alias DESC   -- best hit per chemist
  ) best
  ORDER BY best.s DESC, best.rep_alias DESC;      -- best score first; on a tie the rep's own alias wins
END;


-- =============================================================================
-- 3. Products, aliases, price list, schemes
-- =============================================================================

CREATE TABLE products (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku        text NOT NULL UNIQUE,
  name       text NOT NULL,              -- full display name incl. strength
  pack       text NOT NULL,              -- 'strip of 10', '100 ml bottle'
  category   text NOT NULL,
  is_active  boolean NOT NULL DEFAULT true,
  name_norm  text GENERATED ALWAYS AS (normalize_name(name)) STORED,
  -- The active ingredient and strength ("paracetamol 650"), where known. Matched
  -- like a name; shared by every product with that generic, so an exact hit is
  -- ambiguous and the rep is asked which pack. (Migration 20260930.)
  generic      text,
  generic_norm text GENERATED ALWAYS AS (normalize_name(generic)) STORED
);
CREATE INDEX products_name_trgm ON products USING gin (name_norm gin_trgm_ops);
CREATE INDEX products_generic_trgm ON products USING gin (generic_norm gin_trgm_ops);

CREATE TABLE product_aliases (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id  bigint NOT NULL REFERENCES products(id),
  alias       text NOT NULL,
  alias_norm  text GENERATED ALWAYS AS (normalize_name(alias)) STORED,
  rep_id      bigint REFERENCES users(id),
  source      text NOT NULL DEFAULT 'seed' CHECK (source IN ('seed', 'learned')),
  created_at  timestamptz NOT NULL DEFAULT app_now(),
  UNIQUE NULLS NOT DISTINCT (product_id, alias_norm, rep_id)
);
-- A global alias MAY map to several products ("meridol 650" is two pack sizes):
-- that ambiguity is real and the agent must ask. A rep's learned alias may not.
CREATE UNIQUE INDEX product_aliases_rep_unique ON product_aliases (rep_id, alias_norm) WHERE rep_id IS NOT NULL;
CREATE INDEX product_aliases_trgm ON product_aliases USING gin (alias_norm gin_trgm_ops);
CREATE INDEX product_aliases_product_idx ON product_aliases (product_id);

CREATE FUNCTION match_product(p_rep_id bigint, p_text text)
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

-- Price history. effective_to is EXCLUSIVE and NULL means "still current".
-- The exclusion constraint makes overlapping prices for one product impossible,
-- so "the price on date D" always has exactly zero or one answer.
CREATE TABLE price_list (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id        bigint NOT NULL REFERENCES products(id),
  unit_price_paise  bigint NOT NULL CHECK (unit_price_paise > 0),
  effective_from    date NOT NULL,
  effective_to      date,
  CHECK (effective_to IS NULL OR effective_to > effective_from),
  EXCLUDE USING gist (product_id WITH =, daterange(effective_from, effective_to, '[)') WITH &&)
);

-- Offers. starts_on and ends_on are both INCLUSIVE business dates.
-- buy_x_get_y: for every buy_qty units ordered, free_qty extra units at zero price.
-- percent_off: discount_bp basis points (500 = 5%) off the line value.
-- At most one scheme per product on any date (exclusion constraint), so which
-- scheme applies is never a judgement call.
CREATE TABLE schemes (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code         text NOT NULL UNIQUE,
  name         text NOT NULL,           -- shown on the order summary
  product_id   bigint NOT NULL REFERENCES products(id),
  scheme_type  text NOT NULL CHECK (scheme_type IN ('buy_x_get_y', 'percent_off')),
  buy_qty      integer CHECK (buy_qty > 0),
  free_qty     integer CHECK (free_qty > 0),
  discount_bp  integer CHECK (discount_bp > 0 AND discount_bp < 10000),
  starts_on    date NOT NULL,
  ends_on      date NOT NULL,
  CHECK (ends_on >= starts_on),
  CHECK (
       (scheme_type = 'buy_x_get_y' AND buy_qty IS NOT NULL AND free_qty IS NOT NULL AND discount_bp IS NULL)
    OR (scheme_type = 'percent_off' AND discount_bp IS NOT NULL AND buy_qty IS NULL AND free_qty IS NULL)
  ),
  EXCLUDE USING gist (product_id WITH =, daterange(starts_on, ends_on, '[]') WITH &&)
);


-- =============================================================================
-- 4. Credit ledger
-- =============================================================================

-- What each chemist owes, as an append-only ledger. Positive = owes more.
-- "What the chemist already owes" = SUM(amount_paise). order_charge rows are
-- written by a trigger when an order is submitted to the distributor, and
-- reversed if the distributor rejects it, so the balance cannot drift from the
-- orders.
CREATE TABLE credit_ledger (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  chemist_id    bigint NOT NULL REFERENCES chemists(id),
  entry_type    text NOT NULL CHECK (entry_type IN ('opening_balance', 'order_charge', 'order_reversal', 'payment', 'adjustment')),
  amount_paise  bigint NOT NULL CHECK (amount_paise <> 0),
  order_id      bigint,                  -- FK added after orders exists
  occurred_at   timestamptz NOT NULL DEFAULT app_now(),
  note          text,
  CHECK ((entry_type IN ('order_charge', 'order_reversal')) = (order_id IS NOT NULL)),
  CHECK (entry_type <> 'order_charge'   OR amount_paise > 0),
  CHECK (entry_type <> 'order_reversal' OR amount_paise < 0),
  CHECK (entry_type <> 'payment'        OR amount_paise < 0),
  UNIQUE (order_id, entry_type)          -- one charge and at most one reversal per order
);
CREATE INDEX credit_ledger_chemist_idx ON credit_ledger (chemist_id, occurred_at);
CREATE TRIGGER credit_ledger_append_only BEFORE UPDATE OR DELETE ON credit_ledger
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
-- TRUNCATE fires no row triggers, so it needs its own statement trigger.
CREATE TRIGGER credit_ledger_no_truncate BEFORE TRUNCATE ON credit_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();

CREATE FUNCTION chemist_owed_paise(p_chemist_id bigint) RETURNS bigint
LANGUAGE sql STABLE
RETURN (SELECT coalesce(sum(amount_paise), 0)::bigint FROM credit_ledger WHERE chemist_id = p_chemist_id);


-- =============================================================================
-- 5. Orders
-- =============================================================================

-- Status lifecycle (enforced by orders_guard):
--   draft -> awaiting_confirmation -> confirmed ---------------> submitted -> accepted -> dispatched
--                                  \-> awaiting_credit_approval -/                    \-> distributor_rejected
--   exits: cancelled (before submit), credit_rejected (manager said no)
CREATE TABLE orders (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rep_id                 bigint NOT NULL REFERENCES users(id),
  chemist_id             bigint NOT NULL REFERENCES chemists(id),
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN (
                           'draft', 'awaiting_confirmation', 'awaiting_credit_approval', 'confirmed',
                           'submitted', 'accepted', 'dispatched',
                           'cancelled', 'credit_rejected', 'distributor_rejected')),
  channel                text NOT NULL CHECK (channel IN ('whatsapp', 'email')),
  input_type             text NOT NULL CHECK (input_type IN ('text', 'voice', 'photo', 'excel', 'pdf')),
  source_ref             text,           -- pointer to the raw message/transcript/file, for audit
  created_at             timestamptz NOT NULL DEFAULT app_now(),
  order_date             date NOT NULL,  -- IST business date; set by trigger, drives pricing and routes
  is_off_route           boolean NOT NULL DEFAULT false,  -- set by trigger, snapshot at creation
  -- Confirmation snapshot: what the rep said yes to. The guard compares these
  -- with the live lines, so a changed order cannot ride on an old "yes".
  rep_confirmed_at       timestamptz,
  confirmed_total_paise  bigint,
  confirmed_lines_hash   text,
  -- The confirmation request the rep answered with its code (section 5b).
  -- FK added after order_confirmations exists.
  confirmation_id        bigint UNIQUE,
  -- Duplicate handling: which earlier order this looks like, and when we asked.
  duplicate_of_order_id  bigint REFERENCES orders(id),
  duplicate_prompted_at  timestamptz,
  -- Distributor side
  submitted_at           timestamptz,
  distributor_ref        text UNIQUE,
  distributor_status_at  timestamptz,
  updated_at             timestamptz NOT NULL DEFAULT app_now(),
  CHECK ((rep_confirmed_at IS NULL) = (confirmed_total_paise IS NULL)
     AND (rep_confirmed_at IS NULL) = (confirmed_lines_hash IS NULL)
     AND (rep_confirmed_at IS NULL) = (confirmation_id IS NULL)),
  -- Row-level invariant, independent of the trigger: anything the distributor
  -- has seen must carry a rep confirmation and a submission record.
  CHECK (status NOT IN ('submitted', 'accepted', 'dispatched', 'distributor_rejected')
         OR (rep_confirmed_at IS NOT NULL AND submitted_at IS NOT NULL AND distributor_ref IS NOT NULL))
);
CREATE INDEX orders_rep_created_idx ON orders (rep_id, created_at);
CREATE INDEX orders_chemist_created_idx ON orders (chemist_id, created_at);
CREATE INDEX orders_date_idx ON orders (order_date);
CREATE INDEX orders_open_status_idx ON orders (status)
  WHERE status IN ('draft', 'awaiting_confirmation', 'awaiting_credit_approval', 'confirmed', 'submitted', 'accepted');

ALTER TABLE credit_ledger ADD FOREIGN KEY (order_id) REFERENCES orders(id);

CREATE TABLE order_lines (
  order_id          bigint NOT NULL REFERENCES orders(id),
  line_no           smallint NOT NULL CHECK (line_no > 0),
  product_id        bigint NOT NULL REFERENCES products(id),
  qty               integer NOT NULL CHECK (qty BETWEEN 1 AND 100000),
  -- The four columns below are ALWAYS written by order_lines_price(); anything
  -- the caller supplies is overwritten. The price in a rep's message never
  -- reaches this table.
  unit_price_paise  bigint NOT NULL,
  price_list_id     bigint NOT NULL REFERENCES price_list(id),
  scheme_id         bigint REFERENCES schemes(id),
  free_qty          integer NOT NULL DEFAULT 0 CHECK (free_qty >= 0),
  discount_paise    bigint NOT NULL DEFAULT 0 CHECK (discount_paise >= 0),
  line_total_paise  bigint GENERATED ALWAYS AS (qty * unit_price_paise - discount_paise) STORED,
  raw_text          text,               -- what the rep actually wrote/said for this line
  PRIMARY KEY (order_id, line_no),
  UNIQUE (order_id, product_id)          -- one line per product; the agent merges repeats
);
CREATE INDEX order_lines_product_idx ON order_lines (product_id);

CREATE FUNCTION order_total_paise(p_order_id bigint) RETURNS bigint
LANGUAGE sql STABLE
RETURN (SELECT coalesce(sum(line_total_paise), 0)::bigint FROM order_lines WHERE order_id = p_order_id);

-- Fingerprint of exactly what the rep is shown: products, quantities, free
-- units and money. Stored at confirmation; re-checked before anything moves on.
CREATE FUNCTION order_lines_hash(p_order_id bigint) RETURNS text
LANGUAGE sql STABLE
RETURN (SELECT md5(coalesce(string_agg(product_id || 'x' || qty || '+' || free_qty || '=' || line_total_paise, ',' ORDER BY product_id), ''))
        FROM order_lines WHERE order_id = p_order_id);

-- "Same lines" for duplicate detection: products and quantities only.
CREATE FUNCTION order_lines_signature(p_order_id bigint) RETURNS text
LANGUAGE sql STABLE
RETURN (SELECT string_agg(product_id || 'x' || qty, ',' ORDER BY product_id)
        FROM order_lines WHERE order_id = p_order_id);

CREATE FUNCTION order_transition_allowed(p_from text, p_to text) RETURNS boolean
LANGUAGE sql IMMUTABLE
RETURN (p_from, p_to) IN (
  ('draft', 'awaiting_confirmation'), ('draft', 'cancelled'),
  ('awaiting_confirmation', 'draft'), ('awaiting_confirmation', 'confirmed'),
  ('awaiting_confirmation', 'awaiting_credit_approval'), ('awaiting_confirmation', 'cancelled'),
  ('awaiting_credit_approval', 'confirmed'), ('awaiting_credit_approval', 'credit_rejected'),
  ('awaiting_credit_approval', 'cancelled'),
  ('confirmed', 'submitted'), ('confirmed', 'cancelled'),
  ('submitted', 'accepted'), ('submitted', 'dispatched'), ('submitted', 'distributor_rejected'),
  ('accepted', 'dispatched'), ('accepted', 'distributor_rejected')
);

-- ---- orders: on insert ------------------------------------------------------
-- Every order is born as a draft, for one of the rep's own chemists. The
-- business date and the off-route flag are computed here, not by the caller.
CREATE FUNCTION orders_before_insert() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NEW.status <> 'draft' OR NEW.rep_confirmed_at IS NOT NULL OR NEW.submitted_at IS NOT NULL THEN
    RAISE EXCEPTION 'GUARD: orders must be created as unconfirmed drafts';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.rep_id AND role = 'rep' AND is_active) THEN
    RAISE EXCEPTION 'GUARD: user % is not an active rep', NEW.rep_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM route_stops WHERE rep_id = NEW.rep_id AND chemist_id = NEW.chemist_id) THEN
    RAISE EXCEPTION 'GUARD: chemist % is not one of rep %''s chemists', NEW.chemist_id, NEW.rep_id;
  END IF;
  NEW.order_date := ist_date(NEW.created_at);
  NEW.is_off_route := NOT EXISTS (
    SELECT 1 FROM route_stops
    WHERE rep_id = NEW.rep_id AND chemist_id = NEW.chemist_id
      AND weekday = extract(isodow FROM NEW.order_date));
  NEW.updated_at := NEW.created_at;
  RETURN NEW;
END $$;
CREATE TRIGGER orders_before_insert BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_before_insert();

-- ---- orders: the guard --------------------------------------------------------
-- THIS is the point where an unconfirmed or over-limit order becomes impossible
-- to send, whatever the model was talked into. Any UPDATE that moves an order
-- towards the distributor is checked here, inside the database transaction.
CREATE FUNCTION orders_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_total bigint;
  v_limit bigint;
  v_owed  bigint;
  c       record;   -- an order_confirmations row (that table is created after this function)
BEGIN
  IF (NEW.rep_id, NEW.chemist_id, NEW.created_at, NEW.order_date, NEW.is_off_route)
     IS DISTINCT FROM (OLD.rep_id, OLD.chemist_id, OLD.created_at, OLD.order_date, OLD.is_off_route) THEN
    RAISE EXCEPTION 'GUARD: order %: rep, chemist, dates and route flag are fixed at creation', OLD.id;
  END IF;
  IF OLD.rep_confirmed_at IS NOT NULL AND
     (NEW.rep_confirmed_at, NEW.confirmed_total_paise, NEW.confirmed_lines_hash, NEW.confirmation_id)
     IS DISTINCT FROM (OLD.rep_confirmed_at, OLD.confirmed_total_paise, OLD.confirmed_lines_hash, OLD.confirmation_id) THEN
    RAISE EXCEPTION 'GUARD: order %: a rep confirmation cannot be edited', OLD.id;
  END IF;
  NEW.updated_at := app_now();

  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT order_transition_allowed(OLD.status, NEW.status) THEN
    RAISE EXCEPTION 'GUARD: order %: illegal status change % -> %', OLD.id, OLD.status, NEW.status;
  END IF;

  -- Rule "Confirmation": the rep must have said yes to exactly these lines.
  IF NEW.status IN ('awaiting_credit_approval', 'confirmed', 'submitted') THEN
    v_total := order_total_paise(NEW.id);
    IF NEW.rep_confirmed_at IS NULL THEN
      RAISE EXCEPTION 'GUARD: order %: the rep has not confirmed the final summary', OLD.id;
    END IF;
    IF v_total = 0 THEN
      RAISE EXCEPTION 'GUARD: order %: has no lines', OLD.id;
    END IF;
    IF NEW.confirmed_total_paise <> v_total OR NEW.confirmed_lines_hash <> order_lines_hash(NEW.id) THEN
      RAISE EXCEPTION 'GUARD: order %: changed after the rep confirmed it; show the summary again', OLD.id;
    END IF;
    -- ...and that yes must be a used confirmation request for THIS order, from
    -- THIS rep, for exactly the total and lines frozen when the summary was
    -- shown. Setting rep_confirmed_at by hand is not a confirmation.
    SELECT * INTO c FROM order_confirmations WHERE id = NEW.confirmation_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'GUARD: order %: no verified rep confirmation matches this order', OLD.id;
    END IF;
    IF c.status <> 'used' OR c.order_id <> NEW.id OR c.rep_id <> NEW.rep_id
       OR c.total_paise <> NEW.confirmed_total_paise OR c.lines_hash <> NEW.confirmed_lines_hash THEN
      RAISE EXCEPTION 'GUARD: order %: no verified rep confirmation matches this order', OLD.id;
    END IF;
  END IF;

  -- Rule "Credit": owed + this order over the limit needs an approval for THIS
  -- order at THIS total. The chemist row is locked so two orders for the same
  -- chemist cannot both squeeze through the same headroom concurrently.
  IF NEW.status IN ('confirmed', 'submitted') THEN
    SELECT credit_limit_paise INTO v_limit FROM chemists WHERE id = NEW.chemist_id FOR UPDATE;
    v_owed := chemist_owed_paise(NEW.chemist_id);
    IF v_owed + v_total > v_limit AND NOT EXISTS (
         SELECT 1 FROM credit_approvals a
         WHERE a.order_id = NEW.id AND a.status = 'approved' AND a.order_total_paise = v_total) THEN
      RAISE EXCEPTION 'GUARD: order %: owed % + order % exceeds limit %; needs area manager approval',
        OLD.id, v_owed, v_total, v_limit;
    END IF;
  END IF;

  IF NEW.status = 'submitted' THEN
    NEW.submitted_at := coalesce(NEW.submitted_at, app_now());
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER orders_guard BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_guard();

-- ---- order lines: pricing and locking -----------------------------------------
-- Rule "Price": always from the price list for the order's date. Rule "Schemes":
-- the scheme active on that date applies automatically. Both are computed here
-- with integer arithmetic; the caller only supplies product_id and qty.
CREATE FUNCTION order_lines_price() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_status text;
  v_date   date;
  v_price  price_list;
  v_scheme schemes;
BEGIN
  SELECT status, order_date INTO v_status, v_date FROM orders WHERE id = NEW.order_id;
  IF v_status NOT IN ('draft', 'awaiting_confirmation') THEN
    RAISE EXCEPTION 'GUARD: order %: lines are locked once the order is %', NEW.order_id, v_status;
  END IF;

  SELECT * INTO v_price FROM price_list
   WHERE product_id = NEW.product_id
     AND effective_from <= v_date AND (effective_to IS NULL OR effective_to > v_date);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GUARD: product % has no price on %', NEW.product_id, v_date;
  END IF;
  NEW.unit_price_paise := v_price.unit_price_paise;
  NEW.price_list_id    := v_price.id;

  SELECT * INTO v_scheme FROM schemes
   WHERE product_id = NEW.product_id AND v_date BETWEEN starts_on AND ends_on;
  IF NOT FOUND THEN
    NEW.scheme_id := NULL; NEW.free_qty := 0; NEW.discount_paise := 0;
  ELSIF v_scheme.scheme_type = 'buy_x_get_y' THEN
    NEW.scheme_id      := v_scheme.id;
    NEW.free_qty       := (NEW.qty / v_scheme.buy_qty) * v_scheme.free_qty;   -- integer division = floor
    NEW.discount_paise := 0;
  ELSE -- percent_off
    NEW.scheme_id      := v_scheme.id;
    NEW.free_qty       := 0;
    NEW.discount_paise := (NEW.qty::bigint * NEW.unit_price_paise * v_scheme.discount_bp) / 10000;  -- floor
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER order_lines_price BEFORE INSERT OR UPDATE ON order_lines
  FOR EACH ROW EXECUTE FUNCTION order_lines_price();

CREATE FUNCTION order_lines_before_delete() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF (SELECT status FROM orders WHERE id = OLD.order_id) NOT IN ('draft', 'awaiting_confirmation') THEN
    RAISE EXCEPTION 'GUARD: order %: lines are locked', OLD.order_id;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER order_lines_before_delete BEFORE DELETE ON order_lines
  FOR EACH ROW EXECUTE FUNCTION order_lines_before_delete();

-- Rule "Duplicates": same rep, same chemist, same lines, within ten minutes.
-- Returns the most recent earlier order that matches, or NULL.
CREATE FUNCTION find_possible_duplicate(p_order_id bigint) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  SELECT o2.id
    FROM orders o1
    JOIN orders o2
      ON o2.rep_id = o1.rep_id AND o2.chemist_id = o1.chemist_id
     AND o2.id <> o1.id
     AND o2.created_at BETWEEN o1.created_at - interval '10 minutes' AND o1.created_at
     AND o2.status <> 'cancelled'
   WHERE o1.id = p_order_id
     AND order_lines_signature(o2.id) = order_lines_signature(o1.id)
   ORDER BY o2.created_at DESC
   LIMIT 1;
END;


-- =============================================================================
-- 5b. Confirmation requests
-- =============================================================================

-- Rule "Confirmation", bound to the rep. Showing the summary freezes its exact
-- total and line fingerprint here, with a short code the rep must type back
-- ("YES 4821"). Only confirm_order_by_code (system role, called by code that
-- read the sender from the channel, never by the model) can use a request, and
-- only when the sender resolves to this rep, the code matches, the request is
-- unexpired and unused, and the order still matches what was frozen.
-- The code is not a secret from the model: it ties a "yes" to one version of
-- the summary. Who may say yes is decided by the sender's verified contact.
CREATE TABLE order_confirmations (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id         bigint NOT NULL REFERENCES orders(id),
  rep_id           bigint NOT NULL REFERENCES users(id),
  code             text NOT NULL CHECK (code ~ '^[0-9]{4}$'),
  total_paise      bigint NOT NULL CHECK (total_paise > 0),  -- frozen when the summary was shown
  lines_hash       text NOT NULL,                             -- order_lines_hash() at that moment
  status           text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'used', 'superseded', 'expired', 'locked')),
  failed_attempts  integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  issued_at        timestamptz NOT NULL DEFAULT app_now(),
  expires_at       timestamptz NOT NULL,
  used_at          timestamptz,
  used_channel     text CHECK (used_channel IN ('whatsapp', 'email')),
  -- When the canonical summary carrying this code was first sent to the rep
  -- (summary-integrity postprocessor, section 12). NULL = not shown yet, so the
  -- next reply to the rep must be exactly the canonical summary.
  delivered_at     timestamptz,
  CHECK (expires_at > issued_at),
  CHECK ((status = 'used') = (used_at IS NOT NULL)),
  CHECK ((status = 'used') = (used_channel IS NOT NULL))
);
-- One live request per order, one use per order, and a rep's pending codes
-- are distinct so a typed code names exactly one request.
CREATE UNIQUE INDEX order_confirmations_one_pending ON order_confirmations (order_id) WHERE status = 'pending';
CREATE UNIQUE INDEX order_confirmations_one_used    ON order_confirmations (order_id) WHERE status = 'used';
CREATE UNIQUE INDEX order_confirmations_rep_code    ON order_confirmations (rep_id, code) WHERE status = 'pending';
CREATE INDEX order_confirmations_rep_idx ON order_confirmations (rep_id, issued_at);

ALTER TABLE orders ADD FOREIGN KEY (confirmation_id) REFERENCES order_confirmations(id);

-- A request is born pending; what it froze never changes; once it leaves
-- pending it never changes again. Rows are never deleted.
CREATE FUNCTION order_confirmations_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'pending' OR NEW.used_at IS NOT NULL OR NEW.failed_attempts <> 0 THEN
      RAISE EXCEPTION 'GUARD: confirmation requests must be created pending and unused';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.order_id, NEW.rep_id, NEW.code, NEW.total_paise, NEW.lines_hash, NEW.issued_at, NEW.expires_at)
     IS DISTINCT FROM (OLD.order_id, OLD.rep_id, OLD.code, OLD.total_paise, OLD.lines_hash, OLD.issued_at, OLD.expires_at) THEN
    RAISE EXCEPTION 'GUARD: confirmation request %: frozen fields cannot change', OLD.id;
  END IF;
  IF OLD.status <> 'pending' AND NEW IS DISTINCT FROM OLD THEN
    RAISE EXCEPTION 'GUARD: confirmation request % is % and cannot change', OLD.id, OLD.status;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER order_confirmations_guard BEFORE INSERT OR UPDATE ON order_confirmations
  FOR EACH ROW EXECUTE FUNCTION order_confirmations_guard();
CREATE TRIGGER order_confirmations_no_delete BEFORE DELETE ON order_confirmations
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
CREATE TRIGGER order_confirmations_no_truncate BEFORE TRUNCATE ON order_confirmations
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();


-- =============================================================================
-- 6. Credit approvals
-- =============================================================================

-- One request per order at a time. The approval is pinned to the order AND to
-- the order total it was granted for: "an approval covers that one order only".
-- token goes in the email subject so a reply is matched to the right request
-- even when the manager answers yesterday's thread.
CREATE TABLE credit_approvals (
  id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id               bigint NOT NULL REFERENCES orders(id),
  manager_id             bigint NOT NULL REFERENCES users(id),  -- snapshot: who must decide
  token                  text NOT NULL UNIQUE DEFAULT ('CR-' || upper(substr(md5(gen_random_uuid()::text), 1, 8))),
  status                 text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'superseded')),
  owed_paise_at_request  bigint NOT NULL,
  limit_paise_at_request bigint NOT NULL,
  order_total_paise      bigint NOT NULL,
  requested_at           timestamptz NOT NULL DEFAULT app_now(),
  email_message_id       text,             -- Message-ID of the outbound email, for thread matching
  decided_at             timestamptz,
  decided_by_user_id     bigint REFERENCES users(id),
  decision_note          text,             -- the reply text we acted on
  CHECK ((status = 'pending') = (decided_at IS NULL)),
  CHECK ((status IN ('approved', 'rejected')) = (decided_by_user_id IS NOT NULL))
);
CREATE UNIQUE INDEX credit_approvals_one_pending ON credit_approvals (order_id) WHERE status = 'pending';
CREATE UNIQUE INDEX credit_approvals_one_approved ON credit_approvals (order_id) WHERE status = 'approved';
CREATE INDEX credit_approvals_manager_idx ON credit_approvals (manager_id, status);


-- =============================================================================
-- 7. Distributor callbacks
-- =============================================================================

-- Every callback is stored with its raw payload. distributor_event_id is the
-- idempotency key: a repeat of the same event is recognised, counted, and
-- changes nothing.
CREATE TABLE distributor_events (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  distributor_event_id  text NOT NULL UNIQUE,
  distributor_ref       text NOT NULL,
  order_id              bigint REFERENCES orders(id),
  status_raw            text NOT NULL,
  status_normalized     text,            -- NULL when we do not recognise the status
  occurred_at           timestamptz,     -- the distributor's clock
  received_at           timestamptz NOT NULL DEFAULT app_now(),
  times_received        integer NOT NULL DEFAULT 1,
  last_received_at      timestamptz NOT NULL DEFAULT app_now(),
  payload               jsonb NOT NULL,
  result                text NOT NULL CHECK (result IN ('applied', 'no_change', 'ignored_out_of_order', 'unknown_status', 'unknown_order')),
  rep_notified_at       timestamptz      -- set once the rep has been told; notify exactly once
);
CREATE INDEX distributor_events_order_idx ON distributor_events (order_id, occurred_at);
CREATE INDEX distributor_events_unnotified_idx ON distributor_events (received_at)
  WHERE result = 'applied' AND rep_notified_at IS NULL;
CREATE TRIGGER distributor_events_no_truncate BEFORE TRUNCATE ON distributor_events
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();


-- =============================================================================
-- 8. Audit
-- =============================================================================

-- Every status change, written by trigger so no code path can skip it.
-- Two kinds of "who": actor is the application's claim ('user:12', set by the
-- function that made the change); db_role is the database login that opened the
-- connection, which the caller cannot choose. A mismatch (a manager's actor on a
-- meridian_agent row) would show an application bug or an attack.
CREATE TABLE order_status_history (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id     bigint NOT NULL REFERENCES orders(id),
  from_status  text,
  to_status    text NOT NULL,
  changed_at   timestamptz NOT NULL DEFAULT app_now(),
  actor        text NOT NULL,
  db_role      text NOT NULL DEFAULT session_user
);
CREATE INDEX order_status_history_order_idx ON order_status_history (order_id, changed_at);
CREATE TRIGGER order_status_history_append_only BEFORE UPDATE OR DELETE ON order_status_history
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
CREATE TRIGGER order_status_history_no_truncate BEFORE TRUNCATE ON order_status_history
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();

-- Everything else worth answering "who did what, when": unknown senders,
-- approval decisions (including refused ones), confirmations, learned aliases.
CREATE TABLE audit_log (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at  timestamptz NOT NULL DEFAULT app_now(),
  actor        text NOT NULL,             -- 'user:12', 'agent', 'distributor', 'unknown:+91...'
  action       text NOT NULL,             -- 'identity.unknown_sender', 'credit.decided', ...
  entity_type  text,
  entity_id    text,
  details      jsonb NOT NULL DEFAULT '{}',
  db_role      text NOT NULL DEFAULT session_user   -- the login, not a claim (see order_status_history)
);
CREATE INDEX audit_log_entity_idx ON audit_log (entity_type, entity_id);
CREATE INDEX audit_log_time_idx ON audit_log (occurred_at);
CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();

-- History + ledger side effects of a status change.
CREATE FUNCTION orders_after_write() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_actor text := coalesce(nullif(current_setting('meridian.actor', true), ''), current_user);
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO order_status_history (order_id, from_status, to_status, actor)
    VALUES (NEW.id, NULL, NEW.status, v_actor);
    RETURN NULL;
  END IF;
  IF NEW.status = OLD.status THEN
    RETURN NULL;
  END IF;

  INSERT INTO order_status_history (order_id, from_status, to_status, actor)
  VALUES (NEW.id, OLD.status, NEW.status, v_actor);

  IF NEW.status = 'submitted' THEN
    INSERT INTO credit_ledger (chemist_id, entry_type, amount_paise, order_id, note)
    VALUES (NEW.chemist_id, 'order_charge', order_total_paise(NEW.id), NEW.id, 'order submitted to distributor');
  ELSIF NEW.status = 'distributor_rejected' THEN
    INSERT INTO credit_ledger (chemist_id, entry_type, amount_paise, order_id, note)
    SELECT chemist_id, 'order_reversal', -amount_paise, order_id, 'distributor rejected order'
      FROM credit_ledger WHERE order_id = NEW.id AND entry_type = 'order_charge';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER orders_after_write AFTER INSERT OR UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_after_write();


-- =============================================================================
-- 9. Rule functions the agent's tools will call
-- =============================================================================

-- Caller check shared by every function that acts on an order for a rep:
-- the rep is an active rep and the order is theirs. Also records that rep as the
-- actor for whatever the calling function writes next, overwriting any value
-- the caller may have set. Internal: no runtime role can execute it directly.
CREATE FUNCTION assert_rep_owns_order(p_rep_id bigint, p_order_id bigint) RETURNS void
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM users WHERE id = p_rep_id AND role = 'rep' AND is_active) THEN
    RAISE EXCEPTION 'GUARD: user % is not an active rep', p_rep_id;
  END IF;
  PERFORM 1 FROM orders WHERE id = p_order_id AND rep_id = p_rep_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GUARD: order % does not belong to rep %', p_order_id, p_rep_id;
  END IF;
  PERFORM set_config('meridian.actor', 'user:' || p_rep_id, true);
END $$;

-- The rep typed "YES <code>" on a channel. This is the ONLY way an order gets a
-- rep confirmation. The caller is code that read the sender's contacts from
-- the channel (the Lua preprocessor, as meridian_system), never the model, and
-- there is no rep id parameter: who is confirming is worked out here from
-- those contacts, exactly as resolve_sender does for identity.
--
-- Refusals do not raise: they return a result code (and are audited), so the
-- attempt counter and expiry bookkeeping are kept. Results:
--   confirmed | awaiting_credit_approval        the order moved on
--   unknown_sender | ambiguous_sender | not_a_rep
--   invalid_code     not four digits
--   wrong_code       no request with that code; counts against the rep's
--                    pending requests, which lock after 5 misses
--   expired | already_used | superseded | locked
--   order_not_awaiting | summary_changed   the request is superseded
CREATE FUNCTION confirm_order_by_code(p_channel text, p_sender_contacts text[], p_code text)
RETURNS TABLE (result text, order_id bigint, new_status text, total_paise bigint,
               owed_paise bigint, limit_paise bigint, approval_token text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  v_users  bigint[];
  v_rep    users;
  v_code   text := btrim(coalesce(p_code, ''));
  c        order_confirmations;
  o        orders;
  v_prev   text;
  v_total  bigint;
  v_owed   bigint;
  v_limit  bigint;
  v_token  text;
  v_status text;
  v_prev_actor text;
BEGIN
  IF p_channel NOT IN ('whatsapp', 'email') THEN
    RAISE EXCEPTION 'GUARD: channel must be whatsapp or email, got %', p_channel;
  END IF;

  -- Who is this? Every contact the channel gave us must point at one person.
  SELECT array_agg(DISTINCT s.user_id) INTO v_users
    FROM unnest(coalesce(p_sender_contacts, '{}'::text[])) AS v(val)
    CROSS JOIN LATERAL resolve_sender(p_channel, v.val) AS s;
  IF v_users IS NULL THEN
    result := 'unknown_sender';
  ELSIF cardinality(v_users) > 1 THEN
    result := 'ambiguous_sender';
  ELSE
    SELECT * INTO v_rep FROM users WHERE id = v_users[1];
    IF v_rep.role <> 'rep' THEN
      result := 'not_a_rep';
    ELSIF v_code !~ '^[0-9]{4}$' THEN
      result := 'invalid_code';
    END IF;
  END IF;
  IF result IS NOT NULL THEN
    INSERT INTO audit_log (actor, action, details)
    VALUES (CASE WHEN cardinality(v_users) = 1 THEN 'user:' || v_users[1]
                 ELSE 'unknown:' || left(coalesce(normalize_contact(p_channel, p_sender_contacts[1]), ''), 100) END,
            'confirmation.refused', jsonb_build_object('reason', result, 'channel', p_channel));
    RETURN NEXT;
    RETURN;
  END IF;

  -- Requests left pending past their expiry are closed first.
  UPDATE order_confirmations SET status = 'expired'
   WHERE rep_id = v_rep.id AND status = 'pending' AND expires_at <= app_now();

  SELECT * INTO c FROM order_confirmations
   WHERE rep_id = v_rep.id AND code = v_code AND status = 'pending'
   FOR UPDATE;
  IF NOT FOUND THEN
    SELECT status INTO v_prev FROM order_confirmations
     WHERE rep_id = v_rep.id AND code = v_code ORDER BY issued_at DESC, id DESC LIMIT 1;
    result := CASE v_prev WHEN 'used' THEN 'already_used' WHEN 'expired' THEN 'expired'
                          WHEN 'superseded' THEN 'superseded' WHEN 'locked' THEN 'locked'
                          ELSE 'wrong_code' END;
    IF result = 'wrong_code' THEN
      UPDATE order_confirmations
         SET failed_attempts = failed_attempts + 1,
             status = CASE WHEN failed_attempts + 1 >= 5 THEN 'locked' ELSE status END
       WHERE rep_id = v_rep.id AND status = 'pending';
    END IF;
    INSERT INTO audit_log (actor, action, details)
    VALUES ('user:' || v_rep.id, 'confirmation.refused', jsonb_build_object('reason', result, 'channel', p_channel));
    RETURN NEXT;
    RETURN;
  END IF;

  -- The order must still be waiting for this yes, and still be exactly what was shown.
  SELECT * INTO o FROM orders WHERE id = c.order_id FOR UPDATE;
  order_id := o.id;
  IF o.status <> 'awaiting_confirmation' OR o.rep_id <> v_rep.id THEN
    result := 'order_not_awaiting';
  ELSE
    SELECT credit_limit_paise INTO v_limit FROM chemists WHERE id = o.chemist_id FOR UPDATE;
    v_total := order_total_paise(o.id);
    IF v_total <> c.total_paise OR order_lines_hash(o.id) <> c.lines_hash THEN
      result := 'summary_changed';
    END IF;
  END IF;
  IF result IS NOT NULL THEN
    UPDATE order_confirmations SET status = 'superseded' WHERE id = c.id;
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES ('user:' || v_rep.id, 'confirmation.refused', 'order', o.id::text,
            jsonb_build_object('reason', result, 'channel', p_channel, 'confirmation_id', c.id));
    RETURN NEXT;
    RETURN;
  END IF;

  -- Use the request, then record the rep's yes to exactly what was frozen.
  UPDATE order_confirmations SET status = 'used', used_at = app_now(), used_channel = p_channel WHERE id = c.id;
  v_owed := chemist_owed_paise(o.chemist_id);
  v_prev_actor := current_setting('meridian.actor', true);
  PERFORM set_config('meridian.actor', 'user:' || v_rep.id, true);
  UPDATE orders SET
    rep_confirmed_at      = app_now(),
    confirmed_total_paise = c.total_paise,
    confirmed_lines_hash  = c.lines_hash,
    confirmation_id       = c.id,
    status = CASE WHEN v_owed + c.total_paise > v_limit THEN 'awaiting_credit_approval' ELSE 'confirmed' END
  WHERE id = o.id
  RETURNING status INTO v_status;
  PERFORM set_config('meridian.actor', coalesce(v_prev_actor, ''), true);

  IF v_status = 'awaiting_credit_approval' THEN
    INSERT INTO credit_approvals (order_id, manager_id, owed_paise_at_request, limit_paise_at_request, order_total_paise)
    VALUES (o.id, v_rep.reports_to_id, v_owed, v_limit, c.total_paise)
    RETURNING token INTO v_token;
  END IF;

  INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
  VALUES ('user:' || v_rep.id, 'order.rep_confirmed', 'order', o.id::text,
          jsonb_build_object('total_paise', c.total_paise, 'owed_paise', v_owed, 'limit_paise', v_limit,
                             'result', v_status, 'channel', p_channel, 'confirmation_id', c.id));

  result := v_status; new_status := v_status; total_paise := c.total_paise;
  owed_paise := v_owed; limit_paise := v_limit; approval_token := v_token;
  RETURN NEXT;
END $$;

-- A manager replied to an approval email. Only the manager recorded on the
-- request may decide; a forwarded reply from a colleague, a reply to an
-- already-decided request, or an unknown sender changes nothing (but is logged).
CREATE FUNCTION decide_credit_approval(p_token text, p_from_email text, p_decision text, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  a credit_approvals;
  v_user_id bigint;
  v_prev_actor text;
BEGIN
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'GUARD: decision must be approved or rejected, got %', p_decision;
  END IF;
  SELECT * INTO a FROM credit_approvals WHERE token = upper(btrim(p_token)) FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 'not_found';
  END IF;
  SELECT user_id INTO v_user_id FROM resolve_sender('email', p_from_email);

  IF v_user_id IS DISTINCT FROM a.manager_id THEN
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES (coalesce('user:' || v_user_id, 'unknown:' || normalize_contact('email', p_from_email)),
            'credit.decision_refused', 'credit_approval', a.id::text,
            jsonb_build_object('reason', 'not_authorized', 'attempted', p_decision));
    RETURN 'not_authorized';
  END IF;
  IF a.status = 'pending' AND (SELECT status FROM orders WHERE id = a.order_id) <> 'awaiting_credit_approval' THEN
    -- e.g. the rep cancelled the order while the email sat unanswered.
    UPDATE credit_approvals SET status = 'superseded', decided_at = app_now() WHERE id = a.id;
    a.status := 'superseded';
  END IF;
  IF a.status <> 'pending' THEN
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES ('user:' || v_user_id, 'credit.decision_refused', 'credit_approval', a.id::text,
            jsonb_build_object('reason', 'already_' || a.status, 'attempted', p_decision));
    RETURN 'already_decided';
  END IF;

  UPDATE credit_approvals
     SET status = p_decision, decided_at = app_now(), decided_by_user_id = v_user_id, decision_note = p_note
   WHERE id = a.id;
  -- The order guard re-checks that this approval matches the order's total.
  v_prev_actor := current_setting('meridian.actor', true);
  PERFORM set_config('meridian.actor', 'user:' || v_user_id, true);
  UPDATE orders
     SET status = CASE p_decision WHEN 'approved' THEN 'confirmed' ELSE 'credit_rejected' END
   WHERE id = a.order_id;
  PERFORM set_config('meridian.actor', coalesce(v_prev_actor, ''), true);

  INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
  VALUES ('user:' || v_user_id, 'credit.decided', 'credit_approval', a.id::text,
          jsonb_build_object('decision', p_decision, 'order_id', a.order_id));
  RETURN p_decision;
END $$;

-- A distributor callback. Safe to call any number of times, in any order.
--   repeat of a known event_id      -> 'duplicate' (counted, no effect)
--   unknown distributor_ref          -> 'unknown_order' (stored, no effect)
--   status we do not recognise       -> 'unknown_status' (stored, no effect)
--   same as the order's status       -> 'no_change'
--   would move the order backwards   -> 'ignored_out_of_order'
--   otherwise                        -> 'applied' (order updated; rep to be notified)
CREATE FUNCTION record_distributor_event(
  p_event_id text, p_distributor_ref text, p_status text, p_occurred_at timestamptz, p_payload jsonb)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_id     bigint;
  v_order  orders;
  v_norm   text;
  v_result text;
  v_prev_actor text;
BEGIN
  v_norm := CASE lower(btrim(p_status))
              WHEN 'accepted'   THEN 'accepted'
              WHEN 'dispatched' THEN 'dispatched'
              WHEN 'rejected'   THEN 'distributor_rejected'
            END;
  SELECT * INTO v_order FROM orders WHERE distributor_ref = p_distributor_ref FOR UPDATE;

  v_result := CASE
    WHEN v_order.id IS NULL THEN 'unknown_order'
    WHEN v_norm IS NULL THEN 'unknown_status'
    WHEN v_norm = v_order.status THEN 'no_change'
    WHEN order_transition_allowed(v_order.status, v_norm) THEN 'applied'
    ELSE 'ignored_out_of_order'
  END;

  INSERT INTO distributor_events (distributor_event_id, distributor_ref, order_id, status_raw,
                                  status_normalized, occurred_at, payload, result)
  VALUES (p_event_id, p_distributor_ref, v_order.id, p_status, v_norm, p_occurred_at, p_payload, v_result)
  ON CONFLICT (distributor_event_id) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    UPDATE distributor_events
       SET times_received = times_received + 1, last_received_at = app_now()
     WHERE distributor_event_id = p_event_id;
    RETURN 'duplicate';
  END IF;

  IF v_result = 'applied' THEN
    v_prev_actor := current_setting('meridian.actor', true);
    PERFORM set_config('meridian.actor', 'distributor', true);
    UPDATE orders SET status = v_norm, distributor_status_at = p_occurred_at WHERE id = v_order.id;
    PERFORM set_config('meridian.actor', coalesce(v_prev_actor, ''), true);
  END IF;
  RETURN v_result;
END $$;


-- =============================================================================
-- 10. Reporting views (every number a manager hears comes from these)
-- =============================================================================

CREATE VIEW v_order_totals AS
SELECT o.id AS order_id,
       count(l.line_no)                                   AS line_count,
       coalesce(sum(l.qty), 0)::bigint                    AS units,
       coalesce(sum(l.free_qty), 0)::bigint               AS free_units,
       coalesce(sum(l.qty * l.unit_price_paise), 0)::bigint AS gross_paise,
       coalesce(sum(l.discount_paise), 0)::bigint         AS discount_paise,
       coalesce(sum(l.line_total_paise), 0)::bigint       AS total_paise
FROM orders o
LEFT JOIN order_lines l ON l.order_id = o.id
GROUP BY o.id;

CREATE VIEW v_chemist_credit AS
SELECT c.id AS chemist_id, c.code, c.name, a.code AS area_code, a.name AS area_name,
       c.credit_limit_paise,
       coalesce(sum(cl.amount_paise), 0)::bigint                          AS owed_paise,
       c.credit_limit_paise - coalesce(sum(cl.amount_paise), 0)::bigint   AS headroom_paise,
       coalesce(sum(cl.amount_paise), 0) > c.credit_limit_paise           AS is_over_limit
FROM chemists c
JOIN areas a ON a.id = c.area_id
LEFT JOIN credit_ledger cl ON cl.chemist_id = c.id
GROUP BY c.id, a.id;

-- One row per order with everything a summary or a manager's question needs.
CREATE VIEW v_orders AS
SELECT o.id AS order_id, o.status, o.order_date, o.created_at, o.is_off_route,
       o.channel, o.input_type,
       r.id AS rep_id, r.full_name AS rep_name,
       m.id AS manager_id, m.full_name AS manager_name,
       a.code AS area_code, a.name AS area_name,
       c.id AS chemist_id, c.name AS chemist_name,
       t.line_count, t.units, t.free_units, t.gross_paise, t.discount_paise, t.total_paise,
       o.duplicate_of_order_id, o.distributor_ref
FROM orders o
JOIN users r    ON r.id = o.rep_id
JOIN users m    ON m.id = r.reports_to_id
JOIN areas a    ON a.id = r.area_id
JOIN chemists c ON c.id = o.chemist_id
JOIN v_order_totals t ON t.order_id = o.id;


-- =============================================================================
-- 11. Thin wrappers for the runtime roles
-- =============================================================================
-- meridian_agent and meridian_system have no INSERT/UPDATE/DELETE on any table
-- (privileges.sql). Each workflow step that used to be a direct write is one of
-- these functions instead. They add caller checks only: every business rule
-- (price, schemes, credit, confirmation, transitions) stays in the triggers
-- above and fires exactly as before. Each one sets meridian.actor itself, so an
-- actor the caller set beforehand is overwritten.
--
-- p_rep_id is always the rep the caller resolved from the channel, never a
-- value taken from the model. The database cannot check that; it can only check
-- that the rep is real and that the order or chemist is theirs.

-- ---- agent: building an order -------------------------------------------------
CREATE FUNCTION create_draft_order(p_rep_id bigint, p_chemist_id bigint, p_channel text,
                                   p_input_type text, p_source_ref text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE v_id bigint;
BEGIN
  PERFORM set_config('meridian.actor', 'user:' || p_rep_id, true);
  -- orders_before_insert refuses an inactive rep or a chemist not on their route.
  INSERT INTO orders (rep_id, chemist_id, channel, input_type, source_ref)
  VALUES (p_rep_id, p_chemist_id, p_channel, p_input_type, p_source_ref)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Adds a product to the order, or changes its quantity if it is already there.
-- Only product and quantity are passed; order_lines_price fills in the money.
CREATE FUNCTION set_order_line(p_rep_id bigint, p_order_id bigint, p_product_id bigint,
                               p_qty integer, p_raw_text text DEFAULT NULL)
RETURNS smallint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE v_line smallint;
BEGIN
  PERFORM assert_rep_owns_order(p_rep_id, p_order_id);
  UPDATE order_lines SET qty = p_qty, raw_text = coalesce(p_raw_text, raw_text)
   WHERE order_id = p_order_id AND product_id = p_product_id
  RETURNING line_no INTO v_line;
  IF NOT FOUND THEN
    INSERT INTO order_lines (order_id, line_no, product_id, qty, raw_text)
    SELECT p_order_id, coalesce(max(line_no), 0) + 1, p_product_id, p_qty, p_raw_text
      FROM order_lines WHERE order_id = p_order_id
    RETURNING line_no INTO v_line;
  END IF;
  RETURN v_line;
END $$;

CREATE FUNCTION remove_order_line(p_rep_id bigint, p_order_id bigint, p_product_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  PERFORM assert_rep_owns_order(p_rep_id, p_order_id);
  DELETE FROM order_lines WHERE order_id = p_order_id AND product_id = p_product_id;  -- locked-lines trigger applies
  RETURN FOUND;
END $$;

-- The summary is being shown to the rep: status -> awaiting_confirmation, a
-- possible duplicate recorded, and a confirmation request issued that freezes
-- this exact total and line fingerprint (section 5b). Showing it again, e.g.
-- after an edit, supersedes the previous request, so an old code stops working.
-- Returns the code to print on the summary ("Reply YES 4821"), the frozen
-- total, the expiry, and the earlier order this may duplicate (or NULL).
-- This function never confirms anything.
CREATE FUNCTION present_order_for_confirmation(p_rep_id bigint, p_order_id bigint)
RETURNS TABLE (confirmation_code text, total_paise bigint, expires_at timestamptz, duplicate_of_order_id bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  v_dup   bigint;
  v_total bigint;
  v_code  text;
  v_exp   timestamptz;
  v_try   int := 0;
BEGIN
  PERFORM assert_rep_owns_order(p_rep_id, p_order_id);
  v_total := order_total_paise(p_order_id);
  IF v_total = 0 THEN
    RAISE EXCEPTION 'GUARD: order %: has no lines', p_order_id;
  END IF;
  v_dup := find_possible_duplicate(p_order_id);
  UPDATE orders                                   -- orders_guard checks the transition
     SET status = 'awaiting_confirmation',
         duplicate_of_order_id = v_dup,
         duplicate_prompted_at = CASE WHEN v_dup IS NOT NULL THEN coalesce(duplicate_prompted_at, app_now()) END
   WHERE id = p_order_id;

  UPDATE order_confirmations SET status = 'superseded' WHERE order_id = p_order_id AND status = 'pending';

  v_exp := app_now() + interval '30 minutes';
  LOOP
    -- 4 digits from gen_random_uuid() (a strong random source), not random().
    v_code := lpad(((('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28)::int) % 10000)::text, 4, '0');
    BEGIN
      INSERT INTO order_confirmations (order_id, rep_id, code, total_paise, lines_hash, expires_at)
      VALUES (p_order_id, p_rep_id, v_code, v_total, order_lines_hash(p_order_id), v_exp);
      EXIT;
    EXCEPTION WHEN unique_violation THEN          -- this rep already has a pending request with this code
      v_try := v_try + 1;
      IF v_try >= 20 THEN RAISE; END IF;
    END;
  END LOOP;

  confirmation_code := v_code; total_paise := v_total; expires_at := v_exp; duplicate_of_order_id := v_dup;
  RETURN NEXT;
END $$;

CREATE FUNCTION return_order_to_draft(p_rep_id bigint, p_order_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  PERFORM assert_rep_owns_order(p_rep_id, p_order_id);
  UPDATE orders SET status = 'draft' WHERE id = p_order_id;          -- orders_guard checks the transition
END $$;

CREATE FUNCTION cancel_order(p_rep_id bigint, p_order_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  PERFORM assert_rep_owns_order(p_rep_id, p_order_id);
  UPDATE orders SET status = 'cancelled' WHERE id = p_order_id;      -- orders_guard checks the transition
END $$;

-- (Alias learning: section 18, from confirmed orders only.)

-- (Submission to the distributor: section 14, system role only.)

-- ---- system only ----------------------------------------------------------------
-- Records the Message-ID of the approval email that was sent, for thread matching.
CREATE FUNCTION set_approval_email_id(p_approval_id bigint, p_message_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  UPDATE credit_approvals SET email_message_id = p_message_id WHERE id = p_approval_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GUARD: credit approval % does not exist', p_approval_id;
  END IF;
END $$;

-- Claims the right to tell the rep about an applied distributor event. Returns
-- true once; every later call returns false, so the rep is told at most once.
CREATE FUNCTION mark_rep_notified(p_event_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  UPDATE distributor_events SET rep_notified_at = app_now()
   WHERE id = p_event_id AND result = 'applied' AND rep_notified_at IS NULL;
  RETURN FOUND;
END $$;

-- A message arrived from a number or address that resolves to nobody.
CREATE FUNCTION log_unknown_sender(p_channel text, p_value text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
BEGIN
  INSERT INTO audit_log (actor, action, details)
  VALUES ('unknown:' || left(coalesce(normalize_contact(p_channel, p_value), p_value, ''), 100),
          'identity.unknown_sender', jsonb_build_object('channel', p_channel));
END $$;


-- =============================================================================
-- 12. Order intake and summary integrity
-- =============================================================================
-- The prepare_order tool and the summary-integrity postprocessor call these as
-- meridian_agent. None of them takes a rep id: the sender is resolved here from
-- the contacts the platform gave the caller (user._luaProfile), exactly as
-- confirm_order_by_code does. All business rules still live in the triggers
-- and functions above; these only combine them.

-- Who is sending? One of: ok | unknown_sender | ambiguous_sender | bad_channel.
-- Every contact must resolve to the same active user. At most 20 contacts.
CREATE FUNCTION identify_sender(p_channel text, p_contacts text[])
RETURNS TABLE (result text, user_id bigint, role text, full_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  v_users bigint[];
  u       users;
BEGIN
  IF p_channel IS NULL OR p_channel NOT IN ('whatsapp', 'email') THEN
    result := 'bad_channel';
    RETURN NEXT;
    RETURN;
  END IF;
  SELECT array_agg(DISTINCT s.user_id) INTO v_users
    FROM unnest((coalesce(p_contacts, '{}'::text[]))[1:20]) AS v(val)
    CROSS JOIN LATERAL resolve_sender(p_channel, v.val) AS s;
  IF v_users IS NULL THEN
    result := 'unknown_sender';
  ELSIF cardinality(v_users) > 1 THEN
    result := 'ambiguous_sender';
  ELSE
    SELECT * INTO u FROM users WHERE id = v_users[1];
    result := 'ok'; user_id := u.id; role := u.role; full_name := u.full_name;
  END IF;
  RETURN NEXT;
END $$;

-- Everything a rep's order summary shows, straight from the database: lines
-- with list price, gross, free units, discount, scheme and line total; the
-- total; off-route; a possible duplicate; a credit preview; the live code.
-- Internal (no runtime role may call it directly). The tool and the
-- postprocessor both render THIS, so they cannot disagree.
CREATE FUNCTION order_summary(p_order_id bigint) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = meridian, public, pg_temp
RETURN (
  SELECT jsonb_build_object(
    'order_id',     o.id,
    'status',       o.status,
    'chemist',      jsonb_build_object('code', c.code, 'name', c.name, 'locality', c.locality),
    'lines',        coalesce((
                      SELECT jsonb_agg(jsonb_build_object(
                               'line_no', l.line_no, 'product', p.name, 'pack', p.pack, 'qty', l.qty,
                               'unit_price_paise', l.unit_price_paise,
                               'gross_paise', l.qty::bigint * l.unit_price_paise,
                               'free_qty', l.free_qty, 'discount_paise', l.discount_paise,
                               'line_total_paise', l.line_total_paise, 'scheme', s.name)
                             ORDER BY l.line_no)
                        FROM order_lines l
                        JOIN products p ON p.id = l.product_id
                        LEFT JOIN schemes s ON s.id = l.scheme_id
                       WHERE l.order_id = o.id), '[]'::jsonb),
    'total_paise',  order_total_paise(o.id),
    'is_off_route', o.is_off_route,
    'duplicate',    CASE WHEN d.id IS NULL THEN NULL ELSE jsonb_build_object(
                      'order_id', d.id, 'status', d.status,
                      'at_ist', to_char(d.created_at AT TIME ZONE 'Asia/Kolkata', 'HH24:MI')) END,
    'credit',       jsonb_build_object(
                      'limit_paise', c.credit_limit_paise,
                      'owed_paise', chemist_owed_paise(c.id),
                      'over_limit', chemist_owed_paise(c.id) + order_total_paise(o.id) > c.credit_limit_paise,
                      'manager_name', m.full_name),
    'confirmation', (SELECT jsonb_build_object(
                       'code', oc.code, 'total_paise', oc.total_paise,
                       'expires_ist', to_char(oc.expires_at AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'))
                       FROM order_confirmations oc WHERE oc.order_id = o.id AND oc.status = 'pending'))
    FROM orders o
    JOIN chemists c ON c.id = o.chemist_id
    JOIN users r ON r.id = o.rep_id
    JOIN users m ON m.id = r.reports_to_id
    LEFT JOIN orders d ON d.id = o.duplicate_of_order_id
   WHERE o.id = p_order_id);

-- One atomic step from a validated intake to a summary waiting for "YES <code>":
--   1. the sender must be exactly one active rep (from contacts, not a parameter)
--   2. the chemist must be on that rep's route; 1-50 lines, integer product ids
--      and quantities, active products; repeated products are merged
--   3. the rep's earlier UNCONFIRMED orders (draft / awaiting_confirmation) for
--      this chemist are superseded: their pending codes die and they are
--      cancelled. Confirmed or later orders are never touched.
--   4. create_draft_order, set_order_line (pricing + schemes by trigger) and
--      present_order_for_confirmation (duplicate check, frozen total and
--      fingerprint, code) do the actual work, unchanged.
-- Any failure rolls back all of it. Returns the order id, superseded order ids
-- and order_summary().
CREATE FUNCTION prepare_order(p_channel text, p_contacts text[], p_chemist_id bigint, p_lines jsonb,
                              p_input_type text DEFAULT 'text', p_source_ref text DEFAULT NULL,
                              p_chemist_text text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  who     record;
  v_order bigint;
  v_sup   bigint[] := '{}';
  v_pids  bigint[];
  v_qtys  bigint[];
  v_raws  text[];
  v_bad   bigint;
  r       record;
BEGIN
  SELECT * INTO who FROM identify_sender(p_channel, p_contacts);
  IF who.result <> 'ok' THEN
    RAISE EXCEPTION 'GUARD: sender not identified (%)', who.result;
  END IF;
  IF who.role <> 'rep' OR NOT EXISTS (SELECT 1 FROM users WHERE id = who.user_id AND is_active) THEN
    RAISE EXCEPTION 'GUARD: only an active rep can place an order';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM route_stops WHERE rep_id = who.user_id AND chemist_id = p_chemist_id) THEN
    RAISE EXCEPTION 'GUARD: chemist % is not one of this rep''s chemists', p_chemist_id;
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'GUARD: an order needs 1 to 100 lines';   -- a big chemist's PO can run to 60+ lines
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
              WHERE jsonb_typeof(e->'product_id') IS DISTINCT FROM 'number'
                 OR jsonb_typeof(e->'qty') IS DISTINCT FROM 'number'
                 OR (e->>'product_id')::numeric <> trunc((e->>'product_id')::numeric)
                 OR (e->>'qty')::numeric <> trunc((e->>'qty')::numeric)
                 OR (e->>'qty')::numeric < 1) THEN
    RAISE EXCEPTION 'GUARD: every line needs an integer product_id and an integer qty of at least 1';
  END IF;

  -- Merged lines, in the order each product first appeared. Held in local
  -- arrays, not a temp table: pg_temp belongs to the caller, and a table the
  -- caller pre-created there (with a trigger) would run with this function's
  -- owner rights.
  SELECT array_agg(m.product_id ORDER BY m.first_pos), array_agg(m.qty ORDER BY m.first_pos),
         array_agg(m.raw_text ORDER BY m.first_pos)
    INTO v_pids, v_qtys, v_raws
    FROM (SELECT (e->>'product_id')::bigint AS product_id, sum((e->>'qty')::bigint) AS qty,
                 left(string_agg(nullif(btrim(e->>'raw_text'), ''), ' + ' ORDER BY pos), 500) AS raw_text,
                 min(pos) AS first_pos
            FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS a(e, pos)
           GROUP BY 1) m;
  IF EXISTS (SELECT 1 FROM unnest(v_qtys) AS q WHERE q > 100000) THEN
    RAISE EXCEPTION 'GUARD: quantity above 100000 for one product';
  END IF;
  SELECT pid INTO v_bad FROM unnest(v_pids) AS pid
   WHERE NOT EXISTS (SELECT 1 FROM products p WHERE p.id = pid AND p.is_active) LIMIT 1;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'GUARD: product % is not an active product', v_bad;
  END IF;

  FOR r IN SELECT id FROM orders
            WHERE rep_id = who.user_id AND chemist_id = p_chemist_id
              AND status IN ('draft', 'awaiting_confirmation')
            ORDER BY id FOR UPDATE LOOP
    UPDATE order_confirmations SET status = 'superseded' WHERE order_id = r.id AND status = 'pending';
    PERFORM cancel_order(who.user_id, r.id);
    v_sup := v_sup || r.id;
  END LOOP;

  v_order := create_draft_order(who.user_id, p_chemist_id, p_channel, coalesce(p_input_type, 'text'), p_source_ref);
  -- What the rep wrote for the chemist: learned as their alias once they confirm (section 18).
  UPDATE orders SET chemist_text = nullif(left(btrim(p_chemist_text), 200), '') WHERE id = v_order;
  FOR i IN 1 .. cardinality(v_pids) LOOP
    PERFORM set_order_line(who.user_id, v_order, v_pids[i], v_qtys[i]::integer, v_raws[i]);
  END LOOP;
  PERFORM present_order_for_confirmation(who.user_id, v_order);

  RETURN jsonb_build_object('order_id', v_order, 'superseded_order_ids', to_jsonb(v_sup),
                            'summary', order_summary(v_order));
END $$;

-- The sender's live summaries: pending, unexpired requests whose order is still
-- awaiting confirmation. `delivered` says whether the canonical summary has
-- already been sent. Nothing for anyone who is not exactly one active rep.
CREATE FUNCTION live_order_summaries(p_channel text, p_contacts text[])
RETURNS TABLE (confirmation_id bigint, order_id bigint, code text, delivered boolean, summary jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE who record;
BEGIN
  SELECT * INTO who FROM identify_sender(p_channel, p_contacts);
  IF who.result <> 'ok' OR who.role <> 'rep' THEN
    RETURN;
  END IF;
  RETURN QUERY
    SELECT oc.id, oc.order_id, oc.code, oc.delivered_at IS NOT NULL, order_summary(oc.order_id)
      FROM order_confirmations oc
      JOIN orders o ON o.id = oc.order_id
     WHERE oc.rep_id = who.user_id AND oc.status = 'pending' AND oc.expires_at > app_now()
       AND o.status = 'awaiting_confirmation'
     ORDER BY oc.issued_at, oc.id;
END $$;

-- The canonical summaries for these requests have been sent to their rep.
-- Only the sender's own pending, undelivered requests are touched.
CREATE FUNCTION mark_summaries_delivered(p_channel text, p_contacts text[], p_confirmation_ids bigint[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  who record;
  n   integer;
BEGIN
  SELECT * INTO who FROM identify_sender(p_channel, p_contacts);
  IF who.result <> 'ok' OR who.role <> 'rep' THEN
    RETURN 0;
  END IF;
  UPDATE order_confirmations SET delivered_at = app_now()
   WHERE id = ANY (p_confirmation_ids) AND rep_id = who.user_id
     AND status = 'pending' AND delivered_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;


-- =============================================================================
-- 13. Notifications (outbox) and credit approval by email
-- =============================================================================
-- The database decides WHAT must be sent and to WHOM, in the same transaction
-- as the event that causes it (a trigger). Lua code only delivers: it claims a
-- row, sends it on the channel, and records the outcome. A crashed sender's
-- lease expires and the row is claimed again, so delivery is at least once;
-- dedupe_key makes a repeated event enqueue nothing new.
CREATE TABLE notification_outbox (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind               text NOT NULL CHECK (kind IN ('credit_approval_request', 'credit_decision_to_rep', 'order_status_to_rep', 'evening_summary')),
  dedupe_key         text NOT NULL UNIQUE,
  recipient_user_id  bigint NOT NULL REFERENCES users(id),
  channel            text NOT NULL CHECK (channel IN ('whatsapp', 'email')),
  payload            jsonb NOT NULL,
  status             text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'sending', 'sent', 'dead', 'suppressed')),
  attempts           integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at    timestamptz NOT NULL DEFAULT app_now(),
  locked_until       timestamptz,
  created_at         timestamptz NOT NULL DEFAULT app_now(),
  sent_at            timestamptz,
  address_used       text,            -- the contact it actually went to
  provider_ref       text,            -- the channel's message / delivery id
  last_error         text,
  CHECK ((status = 'sent') = (sent_at IS NOT NULL))
);
CREATE INDEX notification_outbox_due_idx ON notification_outbox (next_attempt_at) WHERE status IN ('pending', 'sending');
CREATE TRIGGER notification_outbox_no_delete BEFORE DELETE ON notification_outbox
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
CREATE TRIGGER notification_outbox_no_truncate BEFORE TRUNCATE ON notification_outbox
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();

-- A credit approval request was raised (by confirm_order_by_code): email the
-- area manager on record. The payload is everything the email shows, taken
-- from the database now: order lines and totals, what the chemist owes, the
-- limit, and the token the reply must carry.
CREATE FUNCTION credit_approvals_enqueue_request() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  INSERT INTO notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  SELECT 'credit_approval_request', 'credit_request:' || NEW.id, NEW.manager_id, 'email',
         jsonb_build_object(
           'approval_id', NEW.id, 'token', NEW.token, 'order_id', NEW.order_id,
           'manager_name', m.full_name, 'rep_name', r.full_name,
           'chemist', jsonb_build_object('code', c.code, 'name', c.name, 'locality', c.locality),
           'order_total_paise', NEW.order_total_paise, 'owed_paise', NEW.owed_paise_at_request,
           'limit_paise', NEW.limit_paise_at_request,
           'over_by_paise', NEW.owed_paise_at_request + NEW.order_total_paise - NEW.limit_paise_at_request,
           'lines', (order_summary(NEW.order_id))->'lines')
    FROM orders o JOIN users r ON r.id = o.rep_id JOIN users m ON m.id = NEW.manager_id
    JOIN chemists c ON c.id = o.chemist_id
   WHERE o.id = NEW.order_id
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER credit_approvals_enqueue_request AFTER INSERT ON credit_approvals
  FOR EACH ROW EXECUTE FUNCTION credit_approvals_enqueue_request();

-- The manager decided: tell the rep, on WhatsApp if they have a number, else email.
CREATE FUNCTION credit_approvals_enqueue_decision() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NEW.status NOT IN ('approved', 'rejected') OR OLD.status = NEW.status THEN
    RETURN NULL;
  END IF;
  INSERT INTO notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  SELECT 'credit_decision_to_rep', 'credit_decision:' || NEW.id, o.rep_id,
         CASE WHEN EXISTS (SELECT 1 FROM user_contacts uc WHERE uc.user_id = o.rep_id AND uc.channel = 'whatsapp' AND uc.valid_to IS NULL)
              THEN 'whatsapp' ELSE 'email' END,
         jsonb_build_object(
           'approval_id', NEW.id, 'token', NEW.token, 'order_id', NEW.order_id, 'decision', NEW.status,
           'manager_name', m.full_name, 'chemist_name', c.name, 'order_total_paise', NEW.order_total_paise,
           'note', left(coalesce(NEW.decision_note, ''), 300))
    FROM orders o JOIN users m ON m.id = NEW.manager_id JOIN chemists c ON c.id = o.chemist_id
   WHERE o.id = NEW.order_id
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER credit_approvals_enqueue_decision AFTER UPDATE OF status ON credit_approvals
  FOR EACH ROW EXECUTE FUNCTION credit_approvals_enqueue_decision();

-- A distributor callback changed an order (record_distributor_event result
-- 'applied'): tell the rep. Duplicates, out-of-order, unknown orders and
-- unknown statuses change nothing and tell nobody.
CREATE FUNCTION distributor_events_enqueue() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NEW.result <> 'applied' OR NEW.order_id IS NULL THEN
    RETURN NULL;
  END IF;
  INSERT INTO notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  SELECT 'order_status_to_rep', 'distributor_event:' || NEW.id, o.rep_id,
         CASE WHEN EXISTS (SELECT 1 FROM user_contacts uc WHERE uc.user_id = o.rep_id AND uc.channel = 'whatsapp' AND uc.valid_to IS NULL)
              THEN 'whatsapp' ELSE 'email' END,
         jsonb_build_object(
           'event_id', NEW.id, 'order_id', o.id, 'status', NEW.status_normalized,
           'distributor_ref', NEW.distributor_ref, 'chemist_name', c.name,
           'order_total_paise', o.confirmed_total_paise,
           'reason', left(coalesce(NEW.payload->>'reason', ''), 300))
    FROM orders o JOIN chemists c ON c.id = o.chemist_id
   WHERE o.id = NEW.order_id
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER distributor_events_enqueue AFTER INSERT ON distributor_events
  FOR EACH ROW EXECUTE FUNCTION distributor_events_enqueue();

-- Claim up to p_limit due notifications for p_lease_seconds. The address is
-- resolved NOW from the recipient's current contact on that channel (falling
-- back to the other channel), so a retired number is never used. A row with no
-- usable contact is marked dead. Returns what the sender needs, nothing more.
CREATE FUNCTION claim_notifications(p_limit integer DEFAULT 20, p_lease_seconds integer DEFAULT 120)
RETURNS TABLE (id bigint, kind text, channel text, address text, payload jsonb, attempts integer, lua_user_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  r      notification_outbox;
  v_addr text;
  v_chan text;
BEGIN
  FOR r IN SELECT * FROM notification_outbox n
            WHERE (n.status = 'pending' AND n.next_attempt_at <= app_now())
               OR (n.status = 'sending' AND n.locked_until < app_now())
            ORDER BY n.next_attempt_at, n.id
            LIMIT least(greatest(coalesce(p_limit, 20), 1), 100)
            FOR UPDATE SKIP LOCKED LOOP
    v_chan := r.channel;
    SELECT uc.value INTO v_addr FROM user_contacts uc
     WHERE uc.user_id = r.recipient_user_id AND uc.channel = v_chan AND uc.valid_to IS NULL
     ORDER BY uc.valid_from DESC, uc.id DESC LIMIT 1;   -- newest: a reviewer's registered contact wins over seed data
    IF v_addr IS NULL THEN
      v_chan := CASE v_chan WHEN 'whatsapp' THEN 'email' ELSE 'whatsapp' END;
      SELECT uc.value INTO v_addr FROM user_contacts uc
       WHERE uc.user_id = r.recipient_user_id AND uc.channel = v_chan AND uc.valid_to IS NULL
       ORDER BY uc.valid_from DESC, uc.id DESC LIMIT 1;
    END IF;
    IF v_addr IS NULL OR NOT EXISTS (SELECT 1 FROM users u WHERE u.id = r.recipient_user_id AND u.is_active) THEN
      UPDATE notification_outbox SET status = 'dead', last_error = 'no current contact for an active recipient', locked_until = NULL
       WHERE notification_outbox.id = r.id;
      CONTINUE;
    END IF;
    UPDATE notification_outbox
       SET status = 'sending', attempts = attempts + 1, locked_until = app_now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30)),
           address_used = v_addr, channel = v_chan
     WHERE notification_outbox.id = r.id;
    id := r.id; kind := r.kind; channel := v_chan; address := v_addr; payload := r.payload; attempts := r.attempts + 1;
    lua_user_id := (SELECT l.lua_user_id FROM lua_user_links l WHERE l.user_id = r.recipient_user_id AND l.channel = v_chan);
    RETURN NEXT;
  END LOOP;
END $$;

-- The channel accepted it. For an approval email, the provider's message id is
-- also recorded on the request, for thread matching.
CREATE FUNCTION complete_notification(p_id bigint, p_provider_ref text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE r notification_outbox;
BEGIN
  UPDATE notification_outbox
     SET status = 'sent', sent_at = app_now(), locked_until = NULL, provider_ref = left(p_provider_ref, 300), last_error = NULL
   WHERE id = p_id AND status = 'sending'
  RETURNING * INTO r;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF r.kind = 'credit_approval_request' AND p_provider_ref IS NOT NULL THEN
    UPDATE credit_approvals SET email_message_id = left(p_provider_ref, 300)
     WHERE id = (r.payload->>'approval_id')::bigint AND email_message_id IS NULL;
  END IF;
  IF r.kind = 'order_status_to_rep' THEN
    UPDATE distributor_events SET rep_notified_at = app_now()
     WHERE id = (r.payload->>'event_id')::bigint AND rep_notified_at IS NULL;
  END IF;
  RETURN true;
END $$;

-- The send failed: retry after 1, 5, 15, 60, 60 minutes, then give up ('dead').
CREATE FUNCTION fail_notification(p_id bigint, p_error text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  UPDATE notification_outbox
     SET status = CASE WHEN attempts >= 6 THEN 'dead' ELSE 'pending' END,
         next_attempt_at = app_now() + (CASE LEAST(attempts, 5) WHEN 1 THEN interval '1 minute' WHEN 2 THEN interval '5 minutes'
                                          WHEN 3 THEN interval '15 minutes' ELSE interval '60 minutes' END),
         locked_until = NULL, last_error = left(coalesce(p_error, 'unknown'), 300)
   WHERE id = p_id AND status = 'sending'
  RETURNING status INTO v_status;
  RETURN coalesce(v_status, 'not_sending');
END $$;

-- A manager replied to an approval email. The replying identity is the
-- platform's (contacts from user._luaProfile), never a parameter the model or
-- the email text could set: it must be exactly one user, and one of the given
-- contacts must be theirs. decide_credit_approval then checks that this user
-- is the approver on record, that the request is still pending, and applies
-- the decision to that one order (the order guard re-checks credit and the
-- approved total). Anyone else is refused and audited there.
CREATE FUNCTION decide_credit_by_reply(p_contacts text[], p_token text, p_decision text, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  who     record;
  v_email text;
BEGIN
  IF p_token IS NULL OR upper(btrim(p_token)) !~ '^CR-[0-9A-F]{8}$' THEN
    RETURN 'bad_token';
  END IF;
  IF p_decision NOT IN ('approved', 'rejected') THEN
    RETURN 'bad_decision';
  END IF;
  SELECT * INTO who FROM identify_sender('email', p_contacts);
  IF who.result = 'ok' THEN
    SELECT c.val INTO v_email FROM unnest((coalesce(p_contacts, '{}'::text[]))[1:20]) AS c(val)
     WHERE EXISTS (SELECT 1 FROM resolve_sender('email', c.val) s WHERE s.user_id = who.user_id)
     LIMIT 1;
  ELSIF who.result = 'unknown_sender' THEN
    -- Resolves to nobody by definition; passed on so the refusal is audited against it.
    v_email := coalesce((coalesce(p_contacts, '{}'::text[]))[1], '');
  ELSE
    -- Ambiguous (contacts of two people): never pass a contact that could
    -- resolve to an approver. An empty address is refused and audited.
    v_email := '';
  END IF;
  RETURN decide_credit_approval(p_token, v_email, p_decision, left(p_note, 500));
END $$;


-- =============================================================================
-- 14. Submission to the distributor
-- =============================================================================
-- An order that becomes `confirmed` (the rep's code within the limit, or a
-- manager's approval) is queued here by trigger. The distributor-submitter job
-- (system role) claims it, sends it to the distributor with the idempotency
-- key, and records the distributor's reference with submit_order(). The order
-- guard decides, at that moment, whether the order may move to `submitted`:
-- rep confirmation matching the lines, and owed + total within the limit or an
-- approval for exactly this total. Nothing else can submit: the agent role has
-- no submission function at all.
CREATE TABLE distributor_submissions (
  order_id          bigint PRIMARY KEY REFERENCES orders(id),
  idempotency_key   text NOT NULL UNIQUE,           -- sent to the distributor; a resend returns the same reference
  status            text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'sending', 'submitted', 'blocked', 'cancelled', 'dead', 'suppressed')),
  attempts          integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_attempt_at   timestamptz NOT NULL DEFAULT app_now(),
  locked_until      timestamptz,
  created_at        timestamptz NOT NULL DEFAULT app_now(),
  submitted_at      timestamptz,
  distributor_ref   text,
  last_error        text,
  CHECK ((status = 'submitted') = (submitted_at IS NOT NULL))
);
CREATE INDEX distributor_submissions_due_idx ON distributor_submissions (next_attempt_at) WHERE status IN ('pending', 'sending');
CREATE TRIGGER distributor_submissions_no_delete BEFORE DELETE ON distributor_submissions
  FOR EACH ROW EXECUTE FUNCTION forbid_update_delete();
CREATE TRIGGER distributor_submissions_no_truncate BEFORE TRUNCATE ON distributor_submissions
  FOR EACH STATEMENT EXECUTE FUNCTION forbid_update_delete();

-- Queue on `confirmed`; close the queue row whenever the order reaches
-- `submitted` by any path (the seed backfills history that way).
CREATE FUNCTION orders_sync_submission() RETURNS trigger
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NULL;
  END IF;
  IF NEW.status = 'confirmed' THEN
    INSERT INTO distributor_submissions (order_id, idempotency_key) VALUES (NEW.id, 'MER-ORDER-' || NEW.id)
    ON CONFLICT (order_id) DO NOTHING;
  ELSIF NEW.status = 'submitted' THEN
    UPDATE distributor_submissions
       SET status = 'submitted', submitted_at = coalesce(submitted_at, app_now()), distributor_ref = NEW.distributor_ref,
           locked_until = NULL, last_error = NULL
     WHERE order_id = NEW.id AND status <> 'submitted';
  ELSIF NEW.status = 'cancelled' THEN
    UPDATE distributor_submissions SET status = 'cancelled', locked_until = NULL
     WHERE order_id = NEW.id AND status IN ('pending', 'sending', 'blocked');
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER orders_sync_submission AFTER UPDATE OF status ON orders
  FOR EACH ROW EXECUTE FUNCTION orders_sync_submission();

-- Would the order guard let this order move to `submitted` right now? Tried for
-- real inside a subtransaction that is always rolled back, so the answer comes
-- from orders_guard itself (no second copy of the rules). Returns NULL if yes,
-- else the guard's message.
CREATE FUNCTION submission_blocker(p_order_id bigint) RETURNS text
LANGUAGE plpgsql SET search_path = meridian, public, pg_temp AS $$
BEGIN
  BEGIN
    UPDATE orders SET status = 'submitted', distributor_ref = 'DRY-RUN-' || p_order_id WHERE id = p_order_id;
    RAISE EXCEPTION 'MERIDIAN_DRY_RUN_OK';
  EXCEPTION WHEN others THEN
    IF SQLERRM = 'MERIDIAN_DRY_RUN_OK' THEN
      RETURN NULL;
    END IF;
    RETURN left(SQLERRM, 300);
  END;
END $$;

-- Claim up to p_limit confirmed orders that are due for sending, each for a
-- lease. Orders the guard would refuse right now are marked `blocked` and not
-- returned (nothing is sent to the distributor that could not be recorded).
-- Returns what the distributor needs: the key, the chemist, SKUs and
-- quantities (with free units), and the confirmed total.
CREATE FUNCTION claim_submissions(p_limit integer DEFAULT 10, p_lease_seconds integer DEFAULT 120)
RETURNS TABLE (order_id bigint, idempotency_key text, attempts integer, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
#variable_conflict use_column
DECLARE
  s         distributor_submissions;
  v_status  text;
  v_blocker text;
BEGIN
  FOR s IN SELECT * FROM distributor_submissions d
            WHERE (d.status = 'pending' AND d.next_attempt_at <= app_now())
               OR (d.status = 'sending' AND d.locked_until < app_now())
            ORDER BY d.next_attempt_at, d.order_id
            LIMIT least(greatest(coalesce(p_limit, 10), 1), 50)
            FOR UPDATE SKIP LOCKED LOOP
    SELECT o.status INTO v_status FROM orders o WHERE o.id = s.order_id FOR UPDATE;
    IF v_status IS DISTINCT FROM 'confirmed' THEN
      UPDATE distributor_submissions SET status = CASE WHEN v_status = 'submitted' THEN status ELSE 'cancelled' END,
             locked_until = NULL, last_error = 'order is ' || coalesce(v_status, 'missing')
       WHERE distributor_submissions.order_id = s.order_id AND status <> 'submitted';
      CONTINUE;
    END IF;
    v_blocker := submission_blocker(s.order_id);
    IF v_blocker IS NOT NULL THEN
      UPDATE distributor_submissions SET status = 'blocked', locked_until = NULL, last_error = v_blocker
       WHERE distributor_submissions.order_id = s.order_id;
      INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
      VALUES ('service:distributor-submitter', 'submission.blocked', 'order', s.order_id::text, jsonb_build_object('reason', v_blocker));
      CONTINUE;
    END IF;
    UPDATE distributor_submissions
       SET status = 'sending', attempts = attempts + 1, locked_until = app_now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30))
     WHERE distributor_submissions.order_id = s.order_id;
    order_id := s.order_id; idempotency_key := s.idempotency_key; attempts := s.attempts + 1;
    payload := (SELECT jsonb_build_object(
                  'order_ref', s.idempotency_key, 'order_id', o.id, 'order_date', o.order_date,
                  'chemist', jsonb_build_object('code', c.code, 'name', c.name, 'locality', c.locality),
                  'lines', (SELECT jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'pack', p.pack,
                                                                'qty', l.qty, 'free_qty', l.free_qty) ORDER BY l.line_no)
                              FROM order_lines l JOIN products p ON p.id = l.product_id WHERE l.order_id = o.id),
                  'total_paise', o.confirmed_total_paise)
                  FROM orders o JOIN chemists c ON c.id = o.chemist_id WHERE o.id = s.order_id);
    RETURN NEXT;
  END LOOP;
END $$;

-- The distributor accepted the order under p_distributor_ref. Idempotent:
--   submitted          the order moved to `submitted` (ledger charged by trigger)
--   already_submitted  it was already submitted with this same reference
--   conflict           it was submitted with a DIFFERENT reference (nothing changed)
--   not_queued | key_mismatch | bad_ref | not_confirmed | blocked (guard refused; recorded)
CREATE FUNCTION submit_order(p_order_id bigint, p_idempotency_key text, p_distributor_ref text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  s  distributor_submissions;
  o  orders;
  v_prev_actor text;
BEGIN
  SELECT * INTO s FROM distributor_submissions WHERE order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_queued'; END IF;
  IF s.idempotency_key IS DISTINCT FROM p_idempotency_key THEN RETURN 'key_mismatch'; END IF;
  IF p_distributor_ref IS NULL OR p_distributor_ref !~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,63}$' THEN RETURN 'bad_ref'; END IF;

  SELECT * INTO o FROM orders WHERE id = p_order_id FOR UPDATE;
  IF o.status IN ('submitted', 'accepted', 'dispatched', 'distributor_rejected') THEN
    RETURN CASE WHEN o.distributor_ref = p_distributor_ref THEN 'already_submitted' ELSE 'conflict' END;
  END IF;
  IF o.status <> 'confirmed' THEN
    RETURN 'not_confirmed';
  END IF;

  v_prev_actor := current_setting('meridian.actor', true);
  PERFORM set_config('meridian.actor', 'service:distributor-submitter', true);
  BEGIN
    UPDATE orders SET status = 'submitted', distributor_ref = p_distributor_ref WHERE id = p_order_id;
  EXCEPTION WHEN others THEN
    PERFORM set_config('meridian.actor', coalesce(v_prev_actor, ''), true);
    UPDATE distributor_submissions SET status = 'blocked', locked_until = NULL, last_error = left(SQLERRM, 300)
     WHERE order_id = p_order_id;
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES ('service:distributor-submitter', 'submission.blocked', 'order', p_order_id::text,
            jsonb_build_object('reason', left(SQLERRM, 300), 'distributor_ref', p_distributor_ref));
    RETURN 'blocked';
  END;
  PERFORM set_config('meridian.actor', coalesce(v_prev_actor, ''), true);
  INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
  VALUES ('service:distributor-submitter', 'order.submitted', 'order', p_order_id::text,
          jsonb_build_object('distributor_ref', p_distributor_ref, 'idempotency_key', p_idempotency_key));
  RETURN 'submitted';
END $$;

-- Sending failed: retry after 1, 5, 15, 60 minutes, then every hour; give up after 8.
CREATE FUNCTION fail_submission(p_order_id bigint, p_error text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE v_status text;
BEGIN
  UPDATE distributor_submissions
     SET status = CASE WHEN attempts >= 8 THEN 'dead' ELSE 'pending' END,
         next_attempt_at = app_now() + (CASE LEAST(attempts, 4) WHEN 1 THEN interval '1 minute' WHEN 2 THEN interval '5 minutes'
                                          WHEN 3 THEN interval '15 minutes' ELSE interval '60 minutes' END),
         locked_until = NULL, last_error = left(coalesce(p_error, 'unknown'), 300)
   WHERE order_id = p_order_id AND status = 'sending'
  RETURNING status INTO v_status;
  RETURN coalesce(v_status, 'not_sending');
END $$;


-- =============================================================================
-- 15. Evening summary (7 PM IST email)
-- =============================================================================
-- Everything a manager's evening email shows, for one viewer and one business
-- date, from queries only. Scope is visible_rep_ids(viewer): an area manager
-- sees their own reps, the regional head sees every rep. "Ordered today" means
-- the rep confirmed an order dated that day; its value excludes orders the
-- manager or the distributor rejected. Internal: no runtime role may call it.
CREATE FUNCTION evening_summary(p_viewer_id bigint, p_date date) RETURNS jsonb
LANGUAGE sql STABLE SET search_path = meridian, public, pg_temp
RETURN (
  WITH v AS (
    SELECT u.id, u.full_name, u.role, a.name AS area_name
      FROM users u LEFT JOIN areas a ON a.id = u.area_id
     WHERE u.id = p_viewer_id AND u.is_active AND u.role IN ('area_manager', 'regional_head')),
  reps AS (
    SELECT r.id, r.full_name, r.employee_code, ra.name AS area_name
      FROM users r JOIN areas ra ON ra.id = r.area_id
     WHERE EXISTS (SELECT 1 FROM v) AND r.id IN (SELECT visible_rep_ids(p_viewer_id))),
  day AS (
    SELECT o.* FROM orders o
     WHERE o.order_date = p_date AND o.rep_confirmed_at IS NOT NULL AND o.rep_id IN (SELECT id FROM reps)),
  per_rep AS (
    SELECT r.id, r.full_name, r.employee_code, r.area_name,
           count(d.id) AS orders,
           coalesce(sum(d.confirmed_total_paise) FILTER (WHERE d.status NOT IN ('credit_rejected', 'distributor_rejected', 'cancelled')), 0)::bigint AS value_paise,
           count(d.id) FILTER (WHERE d.is_off_route) AS off_route
      FROM reps r LEFT JOIN day d ON d.rep_id = r.id
     GROUP BY r.id, r.full_name, r.employee_code, r.area_name)
  SELECT jsonb_build_object(
    'date', p_date,
    'viewer', (SELECT jsonb_build_object('id', id, 'name', full_name, 'role', role, 'area', area_name) FROM v),
    'team', jsonb_build_object(
      'reps', (SELECT count(*) FROM reps),
      'orders', (SELECT count(*) FROM day),
      'value_paise', (SELECT coalesce(sum(value_paise), 0)::bigint FROM per_rep),
      'off_route', (SELECT count(*) FROM day WHERE is_off_route),
      'by_status', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb) FROM (SELECT status, count(*) AS n FROM day GROUP BY status) s)),
    'reps', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', full_name, 'code', employee_code, 'area', area_name,
                                                          'orders', orders, 'value_paise', value_paise, 'off_route', off_route)
                                       ORDER BY value_paise DESC, full_name), '[]'::jsonb) FROM per_rep),
    'waiting', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'token', a.token, 'order_id', a.order_id, 'rep', r.full_name, 'chemist', c.name,
                         'total_paise', a.order_total_paise,
                         'over_by_paise', a.owed_paise_at_request + a.order_total_paise - a.limit_paise_at_request,
                         'requested_ist', to_char(a.requested_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon HH24:MI'),
                         'manager', m.full_name) ORDER BY a.requested_at, a.id), '[]'::jsonb)
                  FROM credit_approvals a JOIN orders o ON o.id = a.order_id JOIN users r ON r.id = o.rep_id
                  JOIN chemists c ON c.id = o.chemist_id JOIN users m ON m.id = a.manager_id
                 WHERE a.status = 'pending' AND o.status = 'awaiting_credit_approval' AND o.rep_id IN (SELECT id FROM reps)),
    'off_route_orders', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                  'order_id', d.id, 'rep', r.full_name, 'chemist', c.name,
                                  'total_paise', d.confirmed_total_paise, 'status', d.status) ORDER BY d.id), '[]'::jsonb)
                           FROM day d JOIN users r ON r.id = d.rep_id JOIN chemists c ON c.id = d.chemist_id
                          WHERE d.is_off_route))
  WHERE EXISTS (SELECT 1 FROM v));

-- Queue one evening email per active area manager and for the regional head,
-- for p_date (default: today in India). The payload is the summary as of now.
-- Idempotent per recipient per day: a second run the same day queues nothing.
CREATE FUNCTION enqueue_evening_summaries(p_date date DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_date date := coalesce(p_date, ist_date(app_now()));
  n      integer;
BEGIN
  INSERT INTO notification_outbox (kind, dedupe_key, recipient_user_id, channel, payload)
  SELECT 'evening_summary', 'evening:' || u.id || ':' || v_date, u.id, 'email', evening_summary(u.id, v_date)
    FROM users u
   WHERE u.is_active AND u.role IN ('area_manager', 'regional_head')
   ORDER BY u.id
  ON CONFLICT (dedupe_key) DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;


-- =============================================================================
-- 16. Manager and regional-head questions
-- =============================================================================
-- The ONLY way the model gets numbers for a question: one of five fixed
-- reports, computed here. The caller is resolved from the platform contacts
-- (never a parameter) and sees only visible_rep_ids(): an area manager their
-- own reps, the regional head every rep, a rep only themselves. Periods are
-- named ('today', 'last_7_days', ...) and turned into India business dates
-- here, so the model never does date or money arithmetic. Lists are capped at
-- 20 rows; nothing else from the database is returned.
CREATE INDEX orders_rep_date_idx ON orders (rep_id, order_date);

CREATE FUNCTION meridian_report(p_channel text, p_contacts text[], p_report text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  who      record;
  v_today  date := ist_date(app_now());
  v_from   date;
  v_to     date;
  v_len    integer;
  v_rep    bigint;
  v_reps   bigint[];
  v_area   bigint;
  v_names  text[];
  prm      jsonb := coalesce(p_params, '{}'::jsonb);
  v_period text := coalesce(nullif(p_params->>'period', ''), 'today');
  v_data   jsonb;
BEGIN
  SELECT * INTO who FROM identify_sender(p_channel, p_contacts);
  IF who.result <> 'ok' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_identified');
  END IF;
  IF p_report IS NULL OR p_report NOT IN ('orders_summary', 'pending_approvals', 'dispatch_status', 'over_limit_chemists', 'rep_comparison') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_report');
  END IF;
  SELECT array_agg(x) INTO v_reps FROM visible_rep_ids(who.user_id) AS x;
  v_reps := coalesce(v_reps, '{}');

  -- Period -> [v_from, v_to] in India business dates.
  CASE v_period
    WHEN 'today'           THEN v_from := v_today;      v_to := v_today;
    WHEN 'yesterday'       THEN v_from := v_today - 1;  v_to := v_today - 1;
    WHEN 'last_7_days'     THEN v_from := v_today - 6;  v_to := v_today;
    WHEN 'previous_7_days' THEN v_from := v_today - 13; v_to := v_today - 7;
    WHEN 'this_week'       THEN v_from := v_today - (extract(isodow FROM v_today)::int - 1); v_to := v_today;
    WHEN 'this_month'      THEN v_from := date_trunc('month', v_today)::date; v_to := v_today;
    WHEN 'custom' THEN
      BEGIN
        v_from := (prm->>'from')::date;
        v_to := (prm->>'to')::date;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_period');
      END;
      IF v_from IS NULL OR v_to IS NULL OR v_from > v_to OR v_to > v_today OR v_to - v_from > 92 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'bad_period');
      END IF;
    ELSE
      RETURN jsonb_build_object('ok', false, 'error', 'bad_period');
  END CASE;
  v_len := v_to - v_from + 1;

  -- Optional rep filter, matched ONLY among the caller's visible reps: by
  -- employee code, full name, or first name. Not found and out of scope look
  -- the same, so nobody can probe other teams.
  IF nullif(btrim(prm->>'rep'), '') IS NOT NULL THEN
    SELECT array_agg(u.id ORDER BY u.id), array_agg(u.full_name ORDER BY u.id) INTO v_reps, v_names
      FROM users u
     WHERE u.id = ANY (v_reps)
       AND (lower(u.employee_code) = lower(btrim(prm->>'rep'))
            OR normalize_name(u.full_name) = normalize_name(prm->>'rep')
            OR split_part(normalize_name(u.full_name), ' ', 1) = normalize_name(prm->>'rep'));
    IF v_reps IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'rep_not_found');
    ELSIF cardinality(v_reps) > 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'ambiguous_rep', 'candidates', to_jsonb(v_names[1:10]));
    END IF;
    v_rep := v_reps[1];
  ELSIF p_report = 'rep_comparison' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'rep_required');
  END IF;

  IF p_report = 'orders_summary' THEN
    WITH d AS (SELECT o.* FROM orders o
                WHERE o.rep_id = ANY (v_reps) AND o.order_date BETWEEN v_from AND v_to AND o.rep_confirmed_at IS NOT NULL),
         pr AS (SELECT u.full_name, u.employee_code, a.name AS area, count(d.id) AS orders,
                       coalesce(sum(d.confirmed_total_paise) FILTER (WHERE d.status NOT IN ('credit_rejected', 'distributor_rejected', 'cancelled')), 0)::bigint AS value_paise,
                       count(d.id) FILTER (WHERE d.is_off_route) AS off_route
                  FROM users u JOIN areas a ON a.id = u.area_id LEFT JOIN d ON d.rep_id = u.id
                 WHERE u.id = ANY (v_reps) GROUP BY u.id, u.full_name, u.employee_code, a.name)
    SELECT jsonb_build_object(
             'orders', (SELECT count(*) FROM d),
             'value_paise', (SELECT coalesce(sum(value_paise), 0)::bigint FROM pr),
             'off_route', (SELECT count(*) FROM d WHERE is_off_route),
             'by_status', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb) FROM (SELECT status, count(*) AS n FROM d GROUP BY status) s),
             'reps_with_orders', (SELECT count(*) FROM pr WHERE orders > 0),
             'reps_without_orders', (SELECT count(*) FROM pr WHERE orders = 0),
             'reps', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', full_name, 'code', employee_code, 'area', area, 'orders', orders,
                                                                    'value_paise', value_paise, 'off_route', off_route)
                                                ORDER BY value_paise DESC, orders DESC, full_name), '[]'::jsonb)
                        FROM (SELECT * FROM pr WHERE orders > 0 ORDER BY value_paise DESC, orders DESC, full_name LIMIT 20) t))
      INTO v_data;

  ELSIF p_report = 'pending_approvals' THEN
    WITH p AS (SELECT a.*, o.rep_id, o.chemist_id FROM credit_approvals a JOIN orders o ON o.id = a.order_id
                WHERE a.status = 'pending' AND o.status = 'awaiting_credit_approval' AND o.rep_id = ANY (v_reps))
    SELECT jsonb_build_object(
             'count', (SELECT count(*) FROM p),
             'total_paise', (SELECT coalesce(sum(order_total_paise), 0)::bigint FROM p),
             'approvals', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                'order_id', q.order_id, 'rep', r.full_name, 'chemist', c.name, 'manager', m.full_name,
                                'total_paise', q.order_total_paise,
                                'over_by_paise', q.owed_paise_at_request + q.order_total_paise - q.limit_paise_at_request,
                                'requested_ist', to_char(q.requested_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon HH24:MI'))
                              ORDER BY q.requested_at, q.id), '[]'::jsonb)
                             FROM (SELECT * FROM p ORDER BY requested_at, id LIMIT 20) q
                             JOIN users r ON r.id = q.rep_id JOIN chemists c ON c.id = q.chemist_id JOIN users m ON m.id = q.manager_id))
      INTO v_data;

  ELSIF p_report = 'dispatch_status' THEN
    WITH s AS (SELECT o.* FROM orders o
                WHERE o.rep_id = ANY (v_reps) AND o.order_date BETWEEN v_from AND v_to AND o.submitted_at IS NOT NULL)
    SELECT jsonb_build_object(
             'sent_to_distributor', (SELECT count(*) FROM s),
             'awaiting_distributor', (SELECT count(*) FROM s WHERE status = 'submitted'),
             'accepted', (SELECT count(*) FROM s WHERE status = 'accepted'),
             'dispatched', (SELECT count(*) FROM s WHERE status = 'dispatched'),
             'rejected_by_distributor', (SELECT count(*) FROM s WHERE status = 'distributor_rejected'),
             'not_yet_dispatched', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                                       'order_id', t.id, 'rep', r.full_name, 'chemist', c.name, 'status', t.status,
                                       'distributor_ref', t.distributor_ref, 'total_paise', t.confirmed_total_paise,
                                       'sent_ist', to_char(t.submitted_at AT TIME ZONE 'Asia/Kolkata', 'DD Mon HH24:MI'))
                                     ORDER BY t.submitted_at, t.id), '[]'::jsonb)
                                    FROM (SELECT * FROM s WHERE status IN ('submitted', 'accepted') ORDER BY submitted_at, id LIMIT 20) t
                                    JOIN users r ON r.id = t.rep_id JOIN chemists c ON c.id = t.chemist_id))
      INTO v_data;

  ELSIF p_report = 'over_limit_chemists' THEN
    IF nullif(btrim(prm->>'area'), '') IS NOT NULL THEN
      SELECT a.id INTO v_area FROM areas a
       WHERE (lower(a.code) = lower(btrim(prm->>'area')) OR a.name ILIKE '%' || btrim(prm->>'area') || '%')
         AND EXISTS (SELECT 1 FROM users u WHERE u.area_id = a.id AND u.id = ANY (v_reps))
       ORDER BY a.id LIMIT 1;
      IF v_area IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'area_not_found');
      END IF;
    END IF;
    WITH ch AS (SELECT v.* FROM v_chemist_credit v JOIN chemists c ON c.id = v.chemist_id
                 WHERE v.is_over_limit AND (v_area IS NULL OR c.area_id = v_area)
                   AND EXISTS (SELECT 1 FROM route_stops rs WHERE rs.chemist_id = v.chemist_id AND rs.rep_id = ANY (v_reps)))
    SELECT jsonb_build_object(
             'count', (SELECT count(*) FROM ch),
             'chemists', (SELECT coalesce(jsonb_agg(jsonb_build_object('chemist', name, 'area', area_name, 'limit_paise', credit_limit_paise,
                                                                       'owed_paise', owed_paise, 'over_by_paise', -headroom_paise)
                                                    ORDER BY headroom_paise, name), '[]'::jsonb)
                            FROM (SELECT * FROM ch ORDER BY headroom_paise, name LIMIT 20) t))
      INTO v_data;

  ELSE  -- rep_comparison: the period against the same number of days just before it
    WITH w AS (SELECT o.*, CASE WHEN o.order_date >= v_from THEN 'current' ELSE 'previous' END AS win FROM orders o
                WHERE o.rep_id = v_rep AND o.rep_confirmed_at IS NOT NULL AND o.order_date BETWEEN v_from - v_len AND v_to),
         agg AS (SELECT win, count(*) AS orders,
                        coalesce(sum(confirmed_total_paise) FILTER (WHERE status NOT IN ('credit_rejected', 'distributor_rejected', 'cancelled')), 0)::bigint AS value_paise,
                        count(*) FILTER (WHERE status = 'credit_rejected') AS credit_rejected,
                        count(*) FILTER (WHERE status = 'distributor_rejected') AS distributor_rejected,
                        count(*) FILTER (WHERE is_off_route) AS off_route
                   FROM w GROUP BY win)
    SELECT jsonb_build_object(
             'rep', (SELECT full_name FROM users WHERE id = v_rep),
             'current', jsonb_build_object('from', v_from, 'to', v_to,
                           'orders', coalesce((SELECT orders FROM agg WHERE win = 'current'), 0),
                           'value_paise', coalesce((SELECT value_paise FROM agg WHERE win = 'current'), 0),
                           'credit_rejected', coalesce((SELECT credit_rejected FROM agg WHERE win = 'current'), 0),
                           'distributor_rejected', coalesce((SELECT distributor_rejected FROM agg WHERE win = 'current'), 0),
                           'off_route', coalesce((SELECT off_route FROM agg WHERE win = 'current'), 0)),
             'previous', jsonb_build_object('from', v_from - v_len, 'to', v_from - 1,
                           'orders', coalesce((SELECT orders FROM agg WHERE win = 'previous'), 0),
                           'value_paise', coalesce((SELECT value_paise FROM agg WHERE win = 'previous'), 0),
                           'credit_rejected', coalesce((SELECT credit_rejected FROM agg WHERE win = 'previous'), 0),
                           'distributor_rejected', coalesce((SELECT distributor_rejected FROM agg WHERE win = 'previous'), 0),
                           'off_route', coalesce((SELECT off_route FROM agg WHERE win = 'previous'), 0)),
             'change_orders', coalesce((SELECT orders FROM agg WHERE win = 'current'), 0) - coalesce((SELECT orders FROM agg WHERE win = 'previous'), 0),
             'change_value_paise', coalesce((SELECT value_paise FROM agg WHERE win = 'current'), 0) - coalesce((SELECT value_paise FROM agg WHERE win = 'previous'), 0))
      INTO v_data;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'report', p_report,
    'asked_by', jsonb_build_object('name', who.full_name, 'role', who.role),
    'scope', CASE who.role WHEN 'regional_head' THEN 'all teams' WHEN 'area_manager' THEN 'own team' ELSE 'own orders' END,
    'period', jsonb_build_object('name', v_period, 'from', v_from, 'to', v_to),
    'rep_filter', (SELECT full_name FROM users WHERE id = v_rep),
    'data', v_data);
END $$;


-- =============================================================================
-- 17. Identity gate: who is this, before anything reasons about it
-- =============================================================================
-- The identity-gate preprocessor calls this as meridian_system on EVERY
-- inbound message, before the model and before any other preprocessor. It
-- answers only "known or not" and the role: never a name, an id or anything
-- else from Meridian's data, so an unknown sender learns nothing, not even
-- whether a contact is half-registered. A contact that points at two people
-- (a data error) is refused the same way.
--
-- Refusals are audited, at most once per sender per 10 minutes, so a flood
-- from one number cannot bloat audit_log.
CREATE INDEX audit_log_unknown_sender_idx ON audit_log (actor, occurred_at)
  WHERE action = 'identity.unknown_sender';

-- Which Lua user a person is on a channel, as the platform verified it when
-- they last wrote in. Used only to reach them back on WhatsApp through Lua's
-- shared test number, where Channels.send has no channel of ours to send from
-- and user.send() (to that Lua user) is the way back. Written only by
-- screen_sender (system role) from user._luaProfile, never from the model.
CREATE TABLE lua_user_links (
  user_id      bigint NOT NULL REFERENCES users(id),
  channel      text NOT NULL CHECK (channel IN ('whatsapp', 'email')),
  lua_user_id  text NOT NULL CHECK (lua_user_id ~ '^[A-Za-z0-9_:.-]{1,128}$'),
  seen_at      timestamptz NOT NULL DEFAULT app_now(),
  PRIMARY KEY (user_id, channel)
);

CREATE FUNCTION screen_sender(p_channel text, p_contacts text[], p_lua_user_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  who     record;
  v_actor text;
BEGIN
  SELECT * INTO who FROM identify_sender(p_channel, p_contacts);
  IF who.result = 'ok' THEN
    IF p_lua_user_id ~ '^[A-Za-z0-9_:.-]{1,128}$' THEN
      INSERT INTO lua_user_links (user_id, channel, lua_user_id, seen_at)
      VALUES (who.user_id, p_channel, p_lua_user_id, app_now())
      ON CONFLICT (user_id, channel) DO UPDATE SET lua_user_id = EXCLUDED.lua_user_id, seen_at = EXCLUDED.seen_at;
    END IF;
    RETURN jsonb_build_object('result', 'ok', 'role', who.role);
  END IF;
  IF who.result IN ('unknown_sender', 'ambiguous_sender') THEN
    v_actor := 'unknown:' || left(coalesce(normalize_contact(p_channel, p_contacts[1]), ''), 100);
    IF NOT EXISTS (SELECT 1 FROM audit_log
                    WHERE action = 'identity.unknown_sender' AND actor = v_actor
                      AND occurred_at > app_now() - interval '10 minutes') THEN
      INSERT INTO audit_log (actor, action, details)
      VALUES (v_actor, 'identity.unknown_sender',
              jsonb_build_object('channel', p_channel, 'reason', who.result,
                                 'contacts', coalesce(cardinality(p_contacts), 0)));
    END IF;
  END IF;
  RETURN jsonb_build_object('result', coalesce(who.result, 'unknown_sender'));
END $$;


-- =============================================================================
-- 18. Alias learning: each rep's own spellings, remembered after they confirm
-- =============================================================================
-- When a rep confirms an order (typed "YES <code>", section 5b), what they
-- wrote for the chemist and for each line becomes THEIR alias for what the
-- order contained. Next time the same words match exactly for that rep only
-- (match_chemist / match_product already prefer a rep's alias on a tie; no
-- threshold changes). Nothing is learned from an unconfirmed order, from the
-- model, or for anyone else. Learning never blocks or changes a confirmation.
--
-- Deterministic rules (learn_alias_text / learn_*_alias_from_order):
--   * 3..60 characters after normalising, at least one letter (Latin or
--     Devanagari); no merged "a + b" line text; no instruction, money or
--     confirmation words (same idea as the media reader's check).
--   * never a name or global alias that already means something ELSE: a rep
--     cannot make "Cetimer Syrup" mean the tablet, or "ors orange" mean lemon.
--     A global alias that is genuinely ambiguous ("meridol 650": two pack
--     sizes) may be narrowed to the one the rep confirmed.
--   * nothing new is learned when the words already mean exactly that.
--   * one meaning per rep and alias (unique index): a later confirmed choice
--     replaces the rep's earlier learned one (audited); seed aliases are never
--     touched.
--   * at most 300 learned aliases per rep and kind.
-- Every learned, replaced or skipped alias is audited.

-- What the rep wrote for the chemist, kept for learning and for audit.
ALTER TABLE orders ADD COLUMN chemist_text text CHECK (length(chemist_text) <= 200);

CREATE INDEX chemist_aliases_learned_idx ON chemist_aliases (rep_id) WHERE source = 'learned';
CREATE INDEX product_aliases_learned_idx ON product_aliases (rep_id) WHERE source = 'learned';

-- The normalised alias, or NULL when these words must not be learned.
CREATE FUNCTION learn_alias_text(p_text text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
RETURN CASE
  WHEN p_text IS NULL OR position(' + ' IN p_text) > 0 THEN NULL
  WHEN length(normalize_name(p_text)) NOT BETWEEN 3 AND 60 THEN NULL
  WHEN normalize_name(p_text) !~ '[a-zऀ-ॿ]' THEN NULL
  WHEN normalize_name(p_text) ~ '\m(ignore|disregard|instruction|instructions|system|assistant|prompt|override|admin|approve|approved|approval|reject|confirm|confirmed|yes|haan|credit|limit|discount|price|prices|rate|free|total|amount|rupee|rupees|rs|inr|submit|submitted|distributor|password|sql|select|drop|delete|update|insert)\M' THEN NULL
  WHEN normalize_name(p_text) ~ '(हाँ|हां|मंज़ूर|मंजूर|क्रेडिट|डिस्काउंट|फ्री|कीमत)' THEN NULL
  ELSE normalize_name(p_text)
END;

CREATE FUNCTION learn_audit(p_rep bigint, p_action text, p_kind text, p_id bigint, p_details jsonb) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = meridian, public, pg_temp
BEGIN ATOMIC
  INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
  VALUES ('user:' || p_rep, p_action, p_kind, p_id::text, p_details);
END;

-- One product line of a confirmed order. Returns what happened, for the audit
-- and the checks: learned | replaced | known | skipped:<why>.
CREATE FUNCTION learn_product_alias_from_line(p_rep bigint, p_product bigint, p_text text, p_order bigint) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  n      text := learn_alias_text(p_text);
  v_old  product_aliases;
  v_id   bigint;
  v_why  text;
BEGIN
  IF n IS NULL THEN
    v_why := 'not_learnable';
  ELSIF EXISTS (SELECT 1 FROM products WHERE name_norm = n AND id <> p_product) THEN
    v_why := 'names_another_product';
  ELSIF EXISTS (SELECT 1 FROM product_aliases WHERE rep_id IS NULL AND alias_norm = n AND product_id <> p_product)
        AND NOT EXISTS (SELECT 1 FROM product_aliases WHERE rep_id IS NULL AND alias_norm = n AND product_id = p_product) THEN
    v_why := 'alias_of_another_product';
  ELSIF EXISTS (SELECT 1 FROM products WHERE id = p_product AND name_norm = n)
        OR (EXISTS (SELECT 1 FROM product_aliases WHERE rep_id IS NULL AND alias_norm = n AND product_id = p_product)
            AND NOT EXISTS (SELECT 1 FROM product_aliases WHERE rep_id IS NULL AND alias_norm = n AND product_id <> p_product)) THEN
    RETURN 'known';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM learn_audit(p_rep, 'alias.skipped', 'product_alias', NULL,
      jsonb_build_object('reason', v_why, 'alias', left(p_text, 100), 'product_id', p_product, 'order_id', p_order));
    RETURN 'skipped:' || v_why;
  END IF;

  SELECT * INTO v_old FROM product_aliases WHERE rep_id = p_rep AND alias_norm = n;
  IF FOUND AND v_old.product_id = p_product THEN
    RETURN 'known';
  END IF;
  IF NOT FOUND AND (SELECT count(*) FROM product_aliases WHERE rep_id = p_rep AND source = 'learned') >= 300 THEN
    PERFORM learn_audit(p_rep, 'alias.skipped', 'product_alias', NULL,
      jsonb_build_object('reason', 'limit_reached', 'alias', left(p_text, 100), 'product_id', p_product, 'order_id', p_order));
    RETURN 'skipped:limit_reached';
  END IF;
  IF FOUND THEN
    DELETE FROM product_aliases WHERE id = v_old.id;
  END IF;
  INSERT INTO product_aliases (product_id, alias, rep_id, source)
  VALUES (p_product, left(btrim(p_text), 100), p_rep, 'learned') RETURNING id INTO v_id;
  PERFORM learn_audit(p_rep, CASE WHEN v_old.id IS NULL THEN 'alias.learned' ELSE 'alias.replaced' END, 'product_alias', v_id,
    jsonb_build_object('alias', left(p_text, 100), 'product_id', p_product, 'order_id', p_order)
      || CASE WHEN v_old.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('previous_product_id', v_old.product_id) END);
  RETURN CASE WHEN v_old.id IS NULL THEN 'learned' ELSE 'replaced' END;
END $$;

-- The chemist of a confirmed order. Same rules; the chemist must be on the
-- rep's route (match_chemist only ever looks there).
CREATE FUNCTION learn_chemist_alias_from_order(p_rep bigint, p_chemist bigint, p_text text, p_order bigint) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  n      text := learn_alias_text(p_text);
  v_old  chemist_aliases;
  v_id   bigint;
  v_why  text;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN 'known';                                   -- nothing written (the rep picked from options only)
  ELSIF NOT EXISTS (SELECT 1 FROM route_stops WHERE rep_id = p_rep AND chemist_id = p_chemist) THEN
    v_why := 'not_on_route';
  ELSIF n IS NULL THEN
    v_why := 'not_learnable';
  ELSIF EXISTS (SELECT 1 FROM chemists WHERE name_norm = n AND id <> p_chemist) THEN
    v_why := 'names_another_chemist';
  ELSIF EXISTS (SELECT 1 FROM chemist_aliases WHERE rep_id IS NULL AND alias_norm = n AND chemist_id <> p_chemist)
        AND NOT EXISTS (SELECT 1 FROM chemist_aliases WHERE rep_id IS NULL AND alias_norm = n AND chemist_id = p_chemist) THEN
    v_why := 'alias_of_another_chemist';
  ELSIF EXISTS (SELECT 1 FROM chemists WHERE id = p_chemist AND name_norm = n)
        OR (EXISTS (SELECT 1 FROM chemist_aliases WHERE rep_id IS NULL AND alias_norm = n AND chemist_id = p_chemist)
            AND NOT EXISTS (SELECT 1 FROM chemist_aliases WHERE rep_id IS NULL AND alias_norm = n AND chemist_id <> p_chemist)) THEN
    RETURN 'known';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM learn_audit(p_rep, 'alias.skipped', 'chemist_alias', NULL,
      jsonb_build_object('reason', v_why, 'alias', left(p_text, 100), 'chemist_id', p_chemist, 'order_id', p_order));
    RETURN 'skipped:' || v_why;
  END IF;

  SELECT * INTO v_old FROM chemist_aliases WHERE rep_id = p_rep AND alias_norm = n;
  IF FOUND AND v_old.chemist_id = p_chemist THEN
    RETURN 'known';
  END IF;
  IF NOT FOUND AND (SELECT count(*) FROM chemist_aliases WHERE rep_id = p_rep AND source = 'learned') >= 300 THEN
    PERFORM learn_audit(p_rep, 'alias.skipped', 'chemist_alias', NULL,
      jsonb_build_object('reason', 'limit_reached', 'alias', left(p_text, 100), 'chemist_id', p_chemist, 'order_id', p_order));
    RETURN 'skipped:limit_reached';
  END IF;
  IF FOUND THEN
    DELETE FROM chemist_aliases WHERE id = v_old.id;
  END IF;
  INSERT INTO chemist_aliases (chemist_id, alias, rep_id, source)
  VALUES (p_chemist, left(btrim(p_text), 100), p_rep, 'learned') RETURNING id INTO v_id;
  PERFORM learn_audit(p_rep, CASE WHEN v_old.id IS NULL THEN 'alias.learned' ELSE 'alias.replaced' END, 'chemist_alias', v_id,
    jsonb_build_object('alias', left(p_text, 100), 'chemist_id', p_chemist, 'order_id', p_order)
      || CASE WHEN v_old.id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('previous_chemist_id', v_old.chemist_id) END);
  RETURN CASE WHEN v_old.id IS NULL THEN 'learned' ELSE 'replaced' END;
END $$;

-- Learn from the moment the rep's confirmation is recorded (whatever path
-- recorded it). Any failure is audited and swallowed: learning is a
-- convenience and must never undo or block a confirmation.
CREATE FUNCTION orders_learn_aliases() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE l record;
BEGIN
  BEGIN
    PERFORM learn_chemist_alias_from_order(NEW.rep_id, NEW.chemist_id, NEW.chemist_text, NEW.id);
    FOR l IN SELECT product_id, raw_text FROM order_lines WHERE order_id = NEW.id AND raw_text IS NOT NULL ORDER BY line_no LOOP
      PERFORM learn_product_alias_from_line(NEW.rep_id, l.product_id, l.raw_text, NEW.id);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES ('user:' || NEW.rep_id, 'alias.learning_failed', 'order', NEW.id::text, jsonb_build_object('sqlstate', SQLSTATE));
  END;
  RETURN NULL;
END $$;
CREATE TRIGGER orders_learn_aliases AFTER UPDATE OF rep_confirmed_at ON orders
  FOR EACH ROW WHEN (OLD.rep_confirmed_at IS NULL AND NEW.rep_confirmed_at IS NOT NULL)
  EXECUTE FUNCTION orders_learn_aliases();


-- =============================================================================
-- 19. Reviewer registration: put your own WhatsApp number or email on a demo
--     rep, manager or regional head
-- =============================================================================
-- The brief asks for "a documented way to register our own numbers and emails
-- as a rep, a manager and the regional head". This attaches a contact to one
-- of three fixed demo people, so a reviewer inherits a coherent world: the rep
-- has chemists and history, the manager is that rep's manager (approvals and
-- the 7 PM email land there), the regional head sees everything.
--
--   rep            REP-NOI-01  Deepak Chauhan
--   manager        ASM-NOI     Kavita Srivastava (Deepak's manager)
--   regional_head  RH-NORTH    Anjali Mehra
--
-- Called by the reviewer-registration webhook (key-protected) or the local
-- `npm run register` command, as meridian_system. It never touches anyone
-- else: a contact that belongs to any other person is refused, never moved.
-- A contact can move between the three demo people (test as a rep, then as the
-- manager) and can be removed. Everything is audited.
CREATE FUNCTION demo_identity(p_role text) RETURNS text
LANGUAGE sql IMMUTABLE
RETURN CASE p_role WHEN 'rep' THEN 'REP-NOI-01' WHEN 'manager' THEN 'ASM-NOI' WHEN 'regional_head' THEN 'RH-NORTH' END;

CREATE FUNCTION register_demo_contact(p_role text, p_channel text, p_value text, p_remove boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = meridian, public, pg_temp AS $$
DECLARE
  v_target users;
  v_value  text;
  v_cur    user_contacts;
  v_demo   bigint[];
BEGIN
  IF p_channel IS NULL OR p_channel NOT IN ('whatsapp', 'email') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_channel');
  END IF;
  v_value := normalize_contact(p_channel, left(coalesce(p_value, ''), 320));
  IF v_value IS NULL
     OR (p_channel = 'whatsapp' AND v_value !~ '^\+[1-9][0-9]{7,14}$')
     OR (p_channel = 'email' AND v_value !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_contact');
  END IF;
  SELECT array_agg(id) INTO v_demo FROM users WHERE employee_code IN ('REP-NOI-01', 'ASM-NOI', 'RH-NORTH');
  SELECT * INTO v_cur FROM user_contacts WHERE channel = p_channel AND value = v_value AND valid_to IS NULL;
  IF FOUND THEN
    IF NOT (v_cur.user_id = ANY (v_demo)) THEN
      INSERT INTO audit_log (actor, action, details)
      VALUES ('registration', 'identity.registration_refused', jsonb_build_object('reason', 'taken', 'channel', p_channel));
      RETURN jsonb_build_object('ok', false, 'error', 'taken');      -- someone else's contact: never moved
    END IF;
  END IF;

  IF p_remove THEN
    IF v_cur.id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_registered');
    END IF;
    UPDATE user_contacts SET valid_to = greatest(app_now(), valid_from + interval '1 second'), note = 'removed by reviewer registration'
     WHERE id = v_cur.id;
    INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
    VALUES ('registration', 'identity.unregistered', 'user', v_cur.user_id::text, jsonb_build_object('channel', p_channel, 'value', v_value));
    RETURN jsonb_build_object('ok', true, 'status', 'removed', 'channel', p_channel);
  END IF;

  IF demo_identity(p_role) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_role');
  END IF;
  SELECT * INTO v_target FROM users WHERE employee_code = demo_identity(p_role) AND is_active;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_available');
  END IF;
  IF v_cur.user_id = v_target.id THEN
    RETURN jsonb_build_object('ok', true, 'status', 'already_registered', 'role', p_role, 'as', v_target.full_name);
  END IF;
  IF (SELECT count(*) FROM user_contacts WHERE user_id = v_target.id AND valid_to IS NULL AND note = 'reviewer registration') >= 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'limit_reached');
  END IF;
  IF v_cur.id IS NOT NULL THEN                                        -- moving between demo people
    UPDATE user_contacts SET valid_to = greatest(app_now(), valid_from + interval '1 second'), note = 'moved by reviewer registration'
     WHERE id = v_cur.id;
  END IF;
  INSERT INTO user_contacts (user_id, channel, value, valid_from, note)
  VALUES (v_target.id, p_channel, v_value, app_now(), 'reviewer registration');
  INSERT INTO audit_log (actor, action, entity_type, entity_id, details)
  VALUES ('registration', 'identity.registered', 'user', v_target.id::text,
          jsonb_build_object('role', p_role, 'channel', p_channel, 'value', v_value, 'moved_from_user', v_cur.user_id));
  RETURN jsonb_build_object('ok', true, 'status', CASE WHEN v_cur.id IS NULL THEN 'registered' ELSE 'moved' END,
                            'role', p_role, 'as', v_target.full_name, 'channel', p_channel);
END $$;


-- Back to the login role. The seed runs next as that login (a member of
-- meridian_owner), then privileges.sql applies the grants.
RESET ROLE;
