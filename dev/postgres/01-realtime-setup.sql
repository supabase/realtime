-- dev/test

CREATE SCHEMA IF NOT EXISTS realtime AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS _realtime;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_realtime_admin') THEN
    CREATE USER supabase_realtime_admin NOINHERIT CREATEROLE LOGIN REPLICATION;
  END IF;
END $$;

ALTER USER supabase_realtime_admin WITH LOGIN REPLICATION PASSWORD 'postgres';
ALTER USER supabase_realtime_admin SET search_path = public, extensions, realtime;
GRANT CREATE ON DATABASE postgres TO supabase_realtime_admin;
GRANT SET ON PARAMETER log_min_messages TO supabase_realtime_admin;
GRANT anon, authenticated, service_role TO supabase_realtime_admin;
GRANT CREATE, USAGE ON SCHEMA public TO supabase_realtime_admin;
GRANT USAGE ON SCHEMA extensions TO supabase_realtime_admin;
GRANT USAGE ON SCHEMA auth TO supabase_realtime_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO supabase_realtime_admin;
GRANT USAGE ON SCHEMA realtime TO postgres, anon, authenticated, service_role;
GRANT ALL ON SCHEMA realtime TO supabase_realtime_admin WITH GRANT OPTION;
