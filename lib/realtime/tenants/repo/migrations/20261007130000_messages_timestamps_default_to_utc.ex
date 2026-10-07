defmodule Realtime.Tenants.Migrations.MessagesTimestampsDefaultToUtc do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT timezone('utc', now())",
      "ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT now()"
    )

    execute(
      "ALTER TABLE realtime.messages ALTER COLUMN updated_at SET DEFAULT timezone('utc', now())",
      "ALTER TABLE realtime.messages ALTER COLUMN updated_at SET DEFAULT now()"
    )
  end
end
