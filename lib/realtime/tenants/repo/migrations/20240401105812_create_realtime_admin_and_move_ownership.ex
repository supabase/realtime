defmodule Realtime.Tenants.Migrations.CreateRealtimeAdminAndMoveOwnership do
   @moduledoc false

   use Ecto.Migration

   def change do
     # Create role without NOINHERIT and grant to postgres
     execute """
     DO
     $do$
     BEGIN
        IF EXISTS (
           SELECT FROM pg_catalog.pg_roles
           WHERE rolname = 'supabase_realtime_admin') THEN
           RAISE NOTICE 'Role "supabase_realtime_admin" already exists. Skipping.';
        ELSE
           CREATE ROLE supabase_realtime_admin WITH NOLOGIN NOREPLICATION;
           GRANT supabase_realtime_admin TO postgres;
        END IF;
     END
     $do$;
     """

     # Grant privileges to supabase_realtime_admin
     execute "GRANT ALL PRIVILEGES ON SCHEMA realtime TO supabase_realtime_admin"
     execute "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA realtime TO supabase_realtime_admin"
     execute "GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA realtime TO supabase_realtime_admin"
     execute "GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA realtime TO supabase_realtime_admin"

     # Transfer ownership of tables and function
     execute "ALTER TABLE realtime.channels OWNER TO supabase_realtime_admin"
     execute "ALTER TABLE realtime.broadcasts OWNER TO supabase_realtime_admin"
     execute "ALTER TABLE realtime.presences OWNER TO supabase_realtime_admin"
     execute "ALTER FUNCTION realtime.channel_name() OWNER TO supabase_realtime_admin"
   end
 end
