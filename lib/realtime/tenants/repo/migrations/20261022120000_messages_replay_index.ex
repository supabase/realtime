defmodule Realtime.Tenants.Migrations.MessagesReplayIndex do
  @moduledoc false

  use Ecto.Migration

  def up do
    execute """
    CREATE INDEX IF NOT EXISTS messages_replay_index ON realtime.messages
      (topic, inserted_at DESC, (COALESCE(expires_at, 'infinity'::timestamp)))
      WHERE extension = 'broadcast' AND private = true
    """

    execute "DROP INDEX IF EXISTS realtime.messages_inserted_at_topic_index"
  end

  def down do
    execute """
    CREATE INDEX IF NOT EXISTS messages_inserted_at_topic_index ON realtime.messages
      (inserted_at DESC, topic)
      WHERE extension = 'broadcast' AND private IS TRUE
    """

    execute "DROP INDEX IF EXISTS realtime.messages_replay_index"
  end
end
