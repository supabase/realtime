defmodule Realtime.Tenants.Migrations.ChangeMessagesIdType do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add_if_not_exists :uuid, :binary_id,
        primary_key: true,
        default: fragment("gen_random_uuid()")

      remove_if_exists :id, :id
    end

    rename table(:messages), :uuid, to: :id
  end
end
