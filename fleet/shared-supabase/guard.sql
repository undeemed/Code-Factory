-- guard.sql - the shared fleet Supabase is a READ-ONLY TEST FIXTURE.
--
-- Applied by check.sh on every start and every 5-minute tick as supabase_admin
-- (the local superuser). Idempotent. Two layers:
--
--  1. Event triggers reject every DDL command and every DROP unless the role is
--     one of the Supabase service roles that legitimately own schema (auth,
--     storage, realtime partitions, functions). `postgres` - the role the CLI,
--     Studio, psql and every agent script use - is rejected. That covers
--     `supabase db reset|push`, `migration up`, hand-written ALTER/CREATE/DROP,
--     Studio's table editor, and Prisma/Drizzle "push" tooling.
--  2. `postgres` sessions default to read-only transactions, so casual DML
--     through psql/Studio fails too. Application traffic is unaffected: the app
--     talks to PostgREST/GoTrue/Storage as anon/authenticated/service_role,
--     none of which are touched here.
--
-- There will never be a migration on this database (captain, 2026-09-17). If an
-- issue appears to need a schema change the lane stops with needs-decision.

SET client_min_messages = warning;  -- IF EXISTS notices would otherwise fill check.log every 5 min
CREATE SCHEMA IF NOT EXISTS fleet_guard;

CREATE OR REPLACE FUNCTION fleet_guard.block_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
-- session_user, not current_user: under SECURITY DEFINER (or SET ROLE) the
-- latter reports the function owner / assumed role, not who connected.
BEGIN
  IF session_user IN (
    'supabase_admin',
    'supabase_auth_admin',
    'supabase_storage_admin',
    'supabase_realtime_admin',
    'supabase_functions_admin',
    'supabase_replication_admin'
  ) THEN
    RETURN;
  END IF;
  RAISE EXCEPTION USING
    ERRCODE = 'insufficient_privilege',
    MESSAGE = format(
      'fleet shared Supabase is a read-only test fixture: %s by role %s is forbidden. '
      'No migrations, no db reset, no schema edits - ever. '
      'See ~/oss-fleet/shared-supabase/README.md; if the task truly needs a schema change, '
      'append needs-decision [key=schema] and stop.',
      tg_tag, session_user);
END;
$$;

DROP EVENT TRIGGER IF EXISTS fleet_guard_ddl;
CREATE EVENT TRIGGER fleet_guard_ddl
  ON ddl_command_start
  EXECUTE FUNCTION fleet_guard.block_ddl();

DROP EVENT TRIGGER IF EXISTS fleet_guard_drop;
CREATE EVENT TRIGGER fleet_guard_drop
  ON sql_drop
  EXECUTE FUNCTION fleet_guard.block_ddl();

-- Layer 2: the human/agent role reads by default.
ALTER ROLE postgres SET default_transaction_read_only = on;
ALTER ROLE dashboard_user SET default_transaction_read_only = on;

COMMENT ON SCHEMA fleet_guard IS
  'Fleet guard: this database is a shared read-only fixture. Schema changes are rejected by event trigger; see ~/oss-fleet/shared-supabase/README.md';
