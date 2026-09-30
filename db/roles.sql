-- =============================================================================
-- Meridian database roles. Idempotent: safe to run any number of times.
-- Run as the Neon owner login (DATABASE_URL). Roles live at the project level
-- and survive schema resets; the grants that use them are in privileges.sql and
-- are re-applied after every reset.
--
--   meridian_owner     NOLOGIN. Owns every object in schema meridian, so the
--                      SECURITY DEFINER functions run with Meridian's rights
--                      only, not the Neon owner's (which include BYPASSRLS and
--                      pg_write_all_data via neon_superuser).
--   meridian_agent     Tools the model can call. Reads, and the order-building
--                      functions. Cannot approve credit or record callbacks.
--   meridian_system    Code the model cannot call: identity lookup, approval
--                      email replies, distributor webhook, jobs.
--   meridian_readonly  The review panel. Reads everything, writes nothing.
--
-- These are created here in SQL, NOT in the Neon Console: roles created there
-- are made members of neon_superuser. LOGIN and passwords are set by
-- scripts/set-db-logins.mjs so no password ever appears in a SQL file.
-- =============================================================================

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['meridian_owner', 'meridian_agent', 'meridian_system', 'meridian_readonly'] LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

-- The migration login becomes a member of meridian_owner so it can create the
-- schema as that role (SET ROLE) and run the seed with owner rights.
GRANT meridian_owner TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;
DO $$ BEGIN EXECUTE format('GRANT CREATE ON DATABASE %I TO meridian_owner', current_database()); END $$;

-- Postgres lets every role execute every new function by default. Turn that off
-- for anything meridian_owner creates; privileges.sql grants what each role needs.
ALTER DEFAULT PRIVILEGES FOR ROLE meridian_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER ROLE meridian_agent    SET search_path = meridian, public;
ALTER ROLE meridian_agent    SET statement_timeout = '15s';
ALTER ROLE meridian_system   SET search_path = meridian, public;
ALTER ROLE meridian_system   SET statement_timeout = '30s';
ALTER ROLE meridian_readonly SET search_path = meridian, public;
ALTER ROLE meridian_readonly SET statement_timeout = '30s';
ALTER ROLE meridian_readonly SET default_transaction_read_only = on;

-- Refuse to continue if any Meridian role has powers it must not have, or has
-- been made a member of another role (e.g. neon_superuser).
DO $$
DECLARE bad text;
BEGIN
  SELECT string_agg(rolname, ', ') INTO bad FROM pg_roles
   WHERE rolname LIKE 'meridian\_%'
     AND (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'unsafe attributes on role(s): %', bad;
  END IF;
  SELECT string_agg(u.rolname || ' is a member of ' || r.rolname, ', ') INTO bad
    FROM pg_auth_members m JOIN pg_roles u ON u.oid = m.member JOIN pg_roles r ON r.oid = m.roleid
   WHERE u.rolname LIKE 'meridian\_%';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Meridian roles must not belong to other roles: %', bad;
  END IF;
END $$;

SELECT rolname, rolcanlogin, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication
FROM pg_roles WHERE rolname LIKE 'meridian\_%' ORDER BY rolname;
