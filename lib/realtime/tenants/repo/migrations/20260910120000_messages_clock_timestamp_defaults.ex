defmodule Realtime.Tenants.Migrations.MessagesClockTimestampDefaults do
  @moduledoc false

  use Ecto.Migration

  # realtime.send and realtime.send_binary leave inserted_at and updated_at to their column
  # defaults. now() is the transaction start time, so every message sent in one transaction got
  # the same timestamps and replay, which orders by inserted_at, could not tell them apart.
  # clock_timestamp() is the time of each insert. Rows are inserted through the partitioned
  # parent, whose defaults apply.
  def up do
    execute("ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT clock_timestamp()")
    execute("ALTER TABLE realtime.messages ALTER COLUMN updated_at SET DEFAULT clock_timestamp()")
  end

  def down do
    execute("ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT now()")
    execute("ALTER TABLE realtime.messages ALTER COLUMN updated_at SET DEFAULT now()")
  end
end
