defmodule Realtime.Tenants.Migrations.RedefineAuthorizationTables do
  @moduledoc false

  use Ecto.Migration

  def change do
    drop table(:broadcasts, mode: :cascade)
    drop table(:presences, mode: :cascade)
    drop table(:channels, mode: :cascade)

    create table(:messages) do
      add :channel_name, :text, null: false
      add :feature, :text, null: false
      add :event, :text, null: false
      timestamps()
    end

    create index(:messages, [:channel_name])

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
  end
end
