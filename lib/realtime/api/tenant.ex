defmodule Realtime.Api.Tenant do
  @moduledoc """
  Describes a database/tenant which makes use of the realtime service.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field(:name, :string)
    field(:external_id, :string)
    field(:jwt_secret, :string)
    field(:max_concurrent_users, :integer)
    field(:max_events_per_second, :integer)

    has_many(:extensions, Realtime.Api.Extensions,
      foreign_key: :tenant_external_id,
      references: :external_id,
      on_delete: :delete_all,
      on_replace: :delete
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
      :max_concurrent_users
    ])
    |> validate_required([
      :external_id,
      :jwt_secret
    ])
    |> cast_assoc(:extensions, required: true)
  end
end
