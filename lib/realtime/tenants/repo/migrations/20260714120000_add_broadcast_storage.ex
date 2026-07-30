defmodule Realtime.Tenants.Migrations.AddBroadcastStorage do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("ALTER TABLE realtime.messages ADD COLUMN IF NOT EXISTS broadcasted_at timestamp")
  end

  def down do
    execute("ALTER TABLE realtime.messages DROP COLUMN IF EXISTS broadcasted_at")
  end
end
