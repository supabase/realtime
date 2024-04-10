defmodule Realtime.Tenants.Migrations.ChangeIdsToBeUuid do
  @moduledoc false

  use Ecto.Migration

  def change do
    alter table(:channels) do
      add :uuid, :uuid, default: fragment("gen_random_uuid()")
    end

    alter table(:broadcasts) do
      add :uuid, :uuid, default: fragment("gen_random_uuid()")
    end

    alter table(:presences) do
      add :uuid, :uuid, default: fragment("gen_random_uuid()")
    end

    alter table(:broadcasts) do
      remove :id
      remove :channel_id
    end

    alter table(:presences) do
      remove :id
      remove :channel_id
    end

    alter table(:channels) do
      remove :id
    end

    rename table(:channels), :uuid, to: :id
    rename table(:broadcasts), :uuid, to: :id
    rename table(:presences), :uuid, to: :id

    alter table(:channels) do
      modify :id, :uuid, primary_key: true
    end

    alter table(:broadcasts) do
      modify :id, :uuid, primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all, type: :uuid), null: false
    end

    alter table(:presences) do
      modify :id, :uuid, primary_key: true
      add :channel_id, references(:channels, on_delete: :delete_all, type: :uuid), null: false
    end
  end
end
