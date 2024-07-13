defmodule Realtime.Tenants.Migrations.CreateChannels do
  @moduledoc false

  use Ecto.Migration

  def change do
    create_if_not_exists table(:channels, prefix: "realtime") do
      add(:name, :string, null: false)
      timestamps()
    end

    create_if_not_exists unique_index(:channels, [:name], prefix: "realtime")
  end
end
