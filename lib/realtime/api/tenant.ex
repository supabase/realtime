defmodule Realtime.Api.Tenant do
  @moduledoc """
  Describes a database/tenant which makes use of the realtime service.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Realtime.Api.Extensions
  alias Realtime.Crypto

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field(:name, :string)
    field(:external_id, :string)
    field(:jwt_secret, :string)
    field(:jwt_jwks, :map)
    field(:postgres_cdc_default, :string)
    field(:max_concurrent_users, :integer)
    field(:max_events_per_second, :integer)
    field(:max_bytes_per_second, :integer)
    field(:max_channels_per_client, :integer)
    field(:max_joins_per_second, :integer)
    field(:suspend, :boolean, default: false)
    field(:events_per_second_rolling, :float, virtual: true)
    field(:events_per_second_now, :integer, virtual: true)
    field(:notify_private_alpha, :boolean, default: false)
    field(:private_only, :boolean, default: false)

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
    # TODO: remove after infra update
    extension_key =
      if attrs[:extensions] do
        :extensions
      else
        "extensions"
      end

    attrs =
      if attrs[extension_key] do
        ext =
          Enum.map(attrs[extension_key], fn
            %{"type" => "postgres"} = e -> %{e | "type" => "postgres_cdc_rls"}
            e -> e
          end)

        %{attrs | extension_key => ext}
      else
        attrs
      end

    tenant
    |> cast(attrs, [
      :name,
      :external_id,
      :jwt_secret,
      :jwt_jwks,
      :max_concurrent_users,
      :max_events_per_second,
      :postgres_cdc_default,
      :max_bytes_per_second,
      :max_channels_per_client,
      :max_joins_per_second,
      :suspend,
      :notify_private_alpha,
      :private_only
    ])
    |> validate_required([
      :external_id,
      :jwt_secret
    ])
    |> unique_constraint([:external_id])
    |> encrypt_jwt_secret()
    |> maybe_set_default(:max_bytes_per_second, :tenant_max_bytes_per_second)
    |> maybe_set_default(:max_channels_per_client, :tenant_max_channels_per_client)
    |> maybe_set_default(:max_concurrent_users, :tenant_max_concurrent_users)
    |> maybe_set_default(:max_events_per_second, :tenant_max_events_per_second)
    |> maybe_set_default(:max_joins_per_second, :tenant_max_joins_per_second)
    |> cast_assoc(:extensions, with: &Extensions.changeset/2)
  end

  def maybe_set_default(changeset, property, config_key) do
    has_key? = Map.get(changeset.data, property) || Map.get(changeset.changes, property)

    if has_key? do
      changeset
    else
      put_change(changeset, property, Application.fetch_env!(:realtime, config_key))
    end
  end

  def encrypt_jwt_secret(changeset) do
    update_change(changeset, :jwt_secret, &Crypto.encrypt!/1)
  end

  def management_changeset(tenant, attrs) do
    cast(tenant, attrs, [
      :max_concurrent_users,
      :max_events_per_second,
      :max_bytes_per_second,
      :max_channels_per_client,
      :max_joins_per_second,
      :suspend,
      :notify_private_alpha,
      :private_only
    ])
  end
end
