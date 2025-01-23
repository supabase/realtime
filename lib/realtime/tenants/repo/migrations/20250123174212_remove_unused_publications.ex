defmodule Realtime.Tenants.Migrations.RemoveUnusedPublications do
  @moduledoc false
  use Ecto.Migration

  # Due to issues on PG Updates we can't use UNLOGGED tables due to the fact that Sequences on PG14 still need to be logged
  def change do
    execute("""
    DO $$
    DECLARE
      r RECORD;
    BEGIN
    FOR r IN
        SELECT pubname FROM pg_publication WHERE pubname LIKE 'realtime_messages%' or pubname LIKE 'supabase_realtime_messages%'
    LOOP
        EXECUTE 'DROP PUBLICATION IF EXISTS ' || quote_ident(r.pubname) || ';' ;
    END LOOP;
    END $$;
    """)
  end
end
