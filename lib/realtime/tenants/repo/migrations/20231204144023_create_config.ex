defmodule Realtime.Tenants.Migrations.CreateConfig do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    create or replace function realtime.channel_name() returns text as $$
    select nullif(current_setting('realtime.channel_name', true), '')::text;
    $$ language sql stable;
    """)

    execute("""
    GRANT USAGE ON SCHEMA realtime TO postgres, anon, authenticated, service_role
    """)

    execute("""
    GRANT SELECT ON ALL TABLES IN SCHEMA realtime TO postgres, anon, authenticated, service_role
    """)

    execute("""
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA realtime TO postgres, anon, authenticated, service_role
    """)

    execute("""
    GRANT USAGE ON ALL SEQUENCES IN SCHEMA realtime TO postgres, anon, authenticated, service_role
    """)

    execute("""
    ALTER TABLE realtime.channels ENABLE row level security;
    """)
  end
end
