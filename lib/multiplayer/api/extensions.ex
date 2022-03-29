defmodule Multiplayer.Api.Extensions do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "extensions" do
    field(:type, :string)
    field(:settings, :map)
    field(:active, :boolean)
    belongs_to(:tenant, Multiplayer.Api.Tenant, foreign_key: :tenant_external_id, type: :string)
    timestamps()
  end

  @doc false
  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [:type, :tenant_external_id, :settings])
    |> validate_required([:type, :settings])
  end
end
