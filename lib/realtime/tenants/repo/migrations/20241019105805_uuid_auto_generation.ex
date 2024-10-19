defmodule Realtime.Tenants.Migrations.UuidAutoGeneration do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:messages) do
      modify :uuid, :uuid, null: false, default: fragment("gen_random_uuid()")
    end
  end
end
