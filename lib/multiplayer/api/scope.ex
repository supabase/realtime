defmodule Multiplayer.Api.Scope do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scopes" do
    field(:host, :string)
    field(:active, :boolean)

    belongs_to(:tenant, Multiplayer.Api.Tenant)

    timestamps()
  end

  @doc false
  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [:host, :tenant_id])
    |> validate_required([:host, :tenant_id])
  end
end
