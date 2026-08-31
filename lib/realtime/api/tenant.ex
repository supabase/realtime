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
    field(:max_presence_events_per_second, :integer, default: 1000)
    field(:max_payload_size_in_kb, :integer, default: 3000)
    field(:max_bytes_per_second, :integer)
    field(:max_channels_per_client, :integer)
    field(:max_joins_per_second, :integer)
    field(:suspend, :boolean, default: false)
    field(:events_per_second_rolling, :float, virtual: true)
    field(:events_per_second_now, :integer, virtual: true)
    field(:private_only, :boolean, default: false)
    field(:migrations_ran, :integer, default: 0)
    field(:broadcast_adapter, Ecto.Enum, values: [:phoenix, :gen_rpc], default: :gen_rpc)
    field(:max_client_presence_events_per_window, :integer)
    field(:client_presence_window_ms, :integer)
    field(:presence_enabled, :boolean, default: false)
    field(:feature_flags, :map, default: %{})
    field(:gcm_migrated_at, :utc_datetime)

    has_many(:extensions, Realtime.Api.Extensions,
      foreign_key: :tenant_external_id,
      references: :external_id,
      on_delete: :delete_all,
      on_replace: :delete
    )

    timestamps()
  end

  # `opts` are forwarded to `Realtime.Crypto.encrypt!/2`.
  def changeset(tenant, attrs, opts \\ []) do
    # TODO: remove after infra update
    extension_key = if attrs[:extensions], do: :extensions, else: "extensions"

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
      :max_presence_events_per_second,
      :max_payload_size_in_kb,
      :suspend,
      :private_only,
      :migrations_ran,
      :broadcast_adapter,
      :max_client_presence_events_per_window,
      :client_presence_window_ms,
      :presence_enabled,
      :feature_flags
    ])
    |> validate_required([:external_id])
    |> check_constraint(:jwt_secret,
      name: :jwt_secret_or_jwt_jwks_required,
      message: "either jwt_secret or jwt_jwks must be provided"
    )
    |> unique_constraint([:external_id])
    |> encrypt_jwt_secret(opts)
    |> maybe_set_default(:max_bytes_per_second, :tenant_max_bytes_per_second)
    |> maybe_set_default(:max_channels_per_client, :tenant_max_channels_per_client)
    |> maybe_set_default(:max_concurrent_users, :tenant_max_concurrent_users)
    |> maybe_set_default(:max_events_per_second, :tenant_max_events_per_second)
    |> maybe_set_default(:max_joins_per_second, :tenant_max_joins_per_second)
    |> cast_assoc(:extensions, with: &Extensions.changeset(&1, &2, opts))
    |> mark_gcm_migrated()
  end

  def maybe_set_default(changeset, property, config_key) do
    has_key? = Map.get(changeset.data, property) || Map.get(changeset.changes, property)

    if has_key? do
      changeset
    else
      put_change(changeset, property, Application.fetch_env!(:realtime, config_key))
    end
  end

  def encrypt_jwt_secret(changeset, opts \\ [])

  def encrypt_jwt_secret(%Ecto.Changeset{valid?: true, changes: %{jwt_secret: plaintext}} = changeset, opts)
      when is_binary(plaintext),
      do: put_change(changeset, :jwt_secret, Crypto.encrypt!(plaintext, opts))

  def encrypt_jwt_secret(changeset, _opts), do: changeset

  @doc """
  Keeps `gcm_migrated_at` in step with the ciphers the pending write leaves behind.

  Stamped once every encrypted value is AES-256-GCM, cleared again as soon as one goes back to the
  legacy cipher. Clearing is what makes the rollout reversible - a tenant written back to ECB has
  to land in `Realtime.Tenants.EncryptionReconciler`'s reach again, and that module skips anything
  already stamped.
  """
  @spec mark_gcm_migrated(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def mark_gcm_migrated(%Ecto.Changeset{valid?: true} = changeset) do
    case cipher_state(changeset) do
      :gcm -> stamp_gcm_migrated(changeset)
      :legacy -> put_change(changeset, :gcm_migrated_at, nil)
      :unknown -> changeset
    end
  end

  def mark_gcm_migrated(changeset), do: changeset

  defp stamp_gcm_migrated(changeset) do
    if is_nil(get_field(changeset, :gcm_migrated_at)),
      do: put_change(changeset, :gcm_migrated_at, DateTime.utc_now(:second)),
      else: changeset
  end

  # `:unknown` when the extensions are not loaded: they could hold either cipher, so both stamping
  # and clearing would be a guess.
  defp cipher_state(changeset) do
    jwt_secret = get_field(changeset, :jwt_secret)
    extensions = extensions(changeset)

    cond do
      not is_list(extensions) -> :unknown
      is_binary(jwt_secret) and not Crypto.gcm?(jwt_secret) -> :legacy
      Enum.any?(extensions, &legacy_settings?/1) -> :legacy
      true -> :gcm
    end
  end

  # `get_field/2` reads an unloaded assoc as `[]`, which would pass for migrated.
  defp extensions(%Ecto.Changeset{changes: %{extensions: _}} = changeset), do: get_field(changeset, :extensions)
  defp extensions(%Ecto.Changeset{data: %{extensions: extensions}}), do: extensions

  defp legacy_settings?(%Extensions{type: type, settings: settings}),
    do: Crypto.legacy_settings?(settings, Realtime.Extensions.encrypted_settings_keys(type))

  @doc false
  def gcm_migrated_at_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:gcm_migrated_at])
    |> validate_required([:gcm_migrated_at])
  end
end
