defmodule Realtime.FeatureFlags do
  @moduledoc """
  Manages feature flags with optional per-tenant overrides.

  Each flag has a global enabled/disabled state. Tenants can override that state
  via a JSONB map stored on the tenant record.

  Use `enabled?/1` to check the global flag value only.
  Use `enabled?/2` when the flag supports per-tenant overrides. Resolution order:
    1. Tenant-specific override (if present)
    2. Global flag value
    3. `false` when the flag does not exist
  """

  import Ecto.Query
  alias Realtime.Api
  alias Realtime.FeatureFlags.Cache
  alias Realtime.Repo
  alias Realtime.Api.FeatureFlag
  alias Realtime.Tenants.Cache, as: TenantsCache

  @spec list_flags() :: [FeatureFlag.t()]
  def list_flags, do: Repo.all(from f in FeatureFlag, order_by: [asc: f.name])

  @spec get_flag(String.t()) :: FeatureFlag.t() | nil
  def get_flag(name) when is_binary(name), do: Repo.get_by(FeatureFlag, name: name)

  @spec upsert_flag(map()) :: {:ok, FeatureFlag.t()} | {:error, Ecto.Changeset.t()}
  def upsert_flag(attrs) do
    %FeatureFlag{}
    |> FeatureFlag.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:enabled, :updated_at]}, conflict_target: :name, returning: true)
  end

  @spec delete_flag(FeatureFlag.t()) :: {:ok, FeatureFlag.t()} | {:error, Ecto.Changeset.t()}
  def delete_flag(%FeatureFlag{} = flag), do: Repo.delete(flag)

  @spec set_tenant_flag(String.t(), String.t(), boolean()) ::
          {:ok, Realtime.Api.Tenant.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_tenant_flag(flag_name, tenant_id, enabled)
      when is_binary(flag_name) and is_binary(tenant_id) and is_boolean(enabled) do
    case Api.get_tenant_by_external_id(tenant_id, use_replica?: false) do
      nil ->
        {:error, :not_found}

      tenant ->
        updated_flags = Map.put(tenant.feature_flags, flag_name, enabled)
        Api.update_tenant_by_external_id(tenant_id, %{feature_flags: updated_flags})
    end
  end

  @spec enabled?(String.t()) :: boolean()
  def enabled?(flag_name) when is_binary(flag_name) do
    case Cache.get_flag(flag_name) do
      nil -> false
      %FeatureFlag{enabled: enabled} -> enabled
    end
  end

  @spec enabled?(String.t(), String.t()) :: boolean()
  def enabled?(flag_name, tenant_id) when is_binary(flag_name) and is_binary(tenant_id) do
    case Cache.get_flag(flag_name) do
      nil ->
        false

      %FeatureFlag{enabled: global_enabled} ->
        case TenantsCache.get_tenant_by_external_id(tenant_id) do
          nil -> global_enabled
          %{feature_flags: flags} -> Map.get(flags, flag_name, global_enabled)
        end
    end
  end
end
