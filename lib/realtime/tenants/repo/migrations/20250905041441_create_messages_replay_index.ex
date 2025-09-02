defmodule Realtime.Tenants.Migrations.CreateMessagesReplayIndex do
  use Ecto.Migration

  def change do
    create_if_not_exists index(:messages, [{:desc, :inserted_at}, :topic, :private])
  end
end
