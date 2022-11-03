defmodule Realtime.Api.Tenant do
  @moduledoc """
  Describes a database/tenant which makes use of the realtime service.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Realtime.Api.Extensions
  import Realtime.Helpers, only: [encrypt!: 2]

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tenants" do
    field(:name, :string)
    field(:external_id, :string)
    field(:jwt_secret, :string)
    field(:postgres_cdc_default, :string)
    field(:max_concurrent_users, :integer)
    field(:max_events_per_second, :integer)
    field(:events_per_second_rolling, :float, virtual: true)
    field(:events_per_second_now, :integer, virtual: true)

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

    ###

    tenant
    |> cast(attrs, [
      :name,
      :external_id,
      :jwt_secret,
      :max_concurrent_users,
      :max_events_per_second,
      :postgres_cdc_default
    ])
    |> validate_required([
      :external_id,
      :jwt_secret
    ])
    |> unique_constraint([:external_id])
    |> encrypt_jwt_secret()
    |> cast_assoc(:extensions, with: &Extensions.changeset/2)
  end

  def encrypt_jwt_secret(changeset) do
    update_change(changeset, :jwt_secret, fn jwt_secret ->
      secure_key = Application.get_env(:realtime, :db_enc_key)
      encrypt!(jwt_secret, secure_key)
    end)
  end
end
