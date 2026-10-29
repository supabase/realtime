defmodule Realtime.Tenants.Migrations.AddExpiresAtToMessages do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("ALTER TABLE realtime.messages ADD COLUMN IF NOT EXISTS expires_at timestamp")
  end

  def down do
    execute("ALTER TABLE realtime.messages DROP COLUMN IF EXISTS expires_at")
  end
end
