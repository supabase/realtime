defmodule Realtime.Tenants.Migrations.MessagesInsertedAtClockTimestamp do
  @moduledoc false

  use Ecto.Migration

  # realtime.send and realtime.send_binary leave inserted_at to the column default. now() is the
  # transaction start time, so every message sent in one transaction got the same inserted_at and
  # replay, which orders by inserted_at, could not tell them apart. clock_timestamp() is the time
  # of each insert. Rows are inserted through the partitioned parent, whose default applies.
  def up do
    execute("ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT clock_timestamp()")
  end

  def down do
    execute("ALTER TABLE realtime.messages ALTER COLUMN inserted_at SET DEFAULT now()")
  end
end
