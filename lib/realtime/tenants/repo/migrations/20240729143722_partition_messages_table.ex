defmodule Realtime.Tenants.Migrations.PartitionMessagesTable do
  @moduledoc false
  use Ecto.Migration
  @partitions 10
  def change do
    drop table(:messages, drop: :cascade)

    execute """
    CREATE TABLE IF NOT EXISTS realtime.messages (
        id bigserial PRIMARY KEY,
        topic text NOT NULL,
        extension text NOT NULL,
        inserted_at timestamp NOT NULL,
        updated_at timestamp NOT NULL
    ) PARTITION BY HASH (id);
    """

    for partition <- 1..@partitions do
      execute """
      CREATE TABLE realtime.messages_#{partition} PARTITION OF realtime.messages
      FOR VALUES WITH (MODULUS #{@partitions}, REMAINDER #{partition-1});
      """
    end

    create index(:messages, [:topic])
    execute("ALTER TABLE realtime.messages ENABLE row level security")
    execute("GRANT SELECT ON realtime.messages TO postgres, anon, authenticated, service_role")
    execute("GRANT UPDATE ON realtime.messages TO postgres, anon, authenticated, service_role")

    execute("""
    GRANT USAGE ON SEQUENCE realtime.messages_id_seq TO postgres, anon, authenticated, service_role
    """)

    execute("""
    GRANT INSERT ON realtime.messages TO postgres, anon, authenticated, service_role
    """)

    execute("ALTER table realtime.messages OWNER to supabase_realtime_admin")
  end
end
