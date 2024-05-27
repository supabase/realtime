defmodule Realtime.Tenants.Migrations.RedefineAuthorizationTables do
  @moduledoc false

  use Ecto.Migration

  def change do
    drop table(:broadcasts, mode: :cascade)
    drop table(:presences, mode: :cascade)
    drop table(:channels, mode: :cascade)

    create table(:messages) do
      add :topic, :text, null: false
      add :extension, :text, null: false
      timestamps()
    end

    create index(:messages, [:topic])

    execute("ALTER TABLE realtime.messages ENABLE row level security")
    execute("GRANT SELECT ON realtime.messages TO postgres, anon, authenticated, service_role")
    execute("GRANT UPDATE ON realtime.messages TO postgres, anon, authenticated, service_role")

    execute("""
    GRANT INSERT ON realtime.messages TO postgres, anon, authenticated, service_role
    """)

    execute("""
    GRANT USAGE ON SEQUENCE realtime.messages_id_seq TO postgres, anon, authenticated, service_role
    """)

    execute("ALTER table realtime.messages OWNER to supabase_realtime_admin")

    execute("""
    DROP function realtime.channel_name
    """)

    execute("""
    create or replace function realtime.topic() returns text as $$
    select nullif(current_setting('realtime.topic', true), '')::text;
    $$ language sql stable;
    """)

    execute("ALTER function realtime.topic() owner to supabase_realtime_admin")
  end
end
