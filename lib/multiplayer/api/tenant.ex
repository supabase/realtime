defmodule Multiplayer.Api.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field(:name, :string)
    field(:external_id, :string)
    field(:jwt_secret, :string)

    field(:settings, :map,
      default: %{
        max_concurrent_users: 10_000
      }
    )

    field(:active, :boolean, default: false)

    has_many(:extensions, Multiplayer.Api.Extensions,
      foreign_key: :tenant_external_id,
      references: :external_id
    )

    timestamps()
  end

  @doc false
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [
      :name,
      :external_id,
      :jwt_secret,
      :active
    ])
    |> validate_required([
      :external_id,
      :jwt_secret
    ])
  end
end
