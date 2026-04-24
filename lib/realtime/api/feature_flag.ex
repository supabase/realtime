defmodule Realtime.Api.FeatureFlag do
  @moduledoc """
  Ecto schema for a global feature flag.

  Flags have a name (unique) and a boolean enabled state. Per-tenant overrides
  are stored separately on the `Realtime.Api.Tenant` schema as a JSONB map,
  not as associations on this record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "feature_flags" do
    field :name, :string
    field :enabled, :boolean, default: false
    timestamps()
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [:name, :enabled])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
