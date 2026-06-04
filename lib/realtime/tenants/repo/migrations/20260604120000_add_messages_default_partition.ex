defmodule Realtime.Tenants.Migrations.AddMessagesDefaultPartition do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute("""
    CREATE TABLE IF NOT EXISTS realtime.messages_default
    PARTITION OF realtime.messages DEFAULT
    """)
  end
end
