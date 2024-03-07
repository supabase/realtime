defmodule Realtime.Tenants.Cache do
  @moduledoc """
  Cache for Tenants.
  """
  require Cachex.Spec

  alias Realtime.Tenants

  def child_spec(_) do
    %{
      id: __MODULE__,
      start:
        {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: 30_000)]]}
    }
  end

  def get_tenant_by_external_id(keyword), do: apply_repo_fun(__ENV__.function, [keyword])

  @doc """
    Invalidates the cache for a tenant in the local node
  """
  def invalidate_tenant_cache(tenant_id) do
    Cachex.del(__MODULE__, {{:get_tenant_by_external_id, 1}, [tenant_id]})
  end

  @doc """
  Broadcasts a message to invalidate the tenant cache to all connected nodes
  """
  @spec distributed_invalidate_tenant_cache(String.t()) :: :ok
  def distributed_invalidate_tenant_cache(tenant_id) when is_binary(tenant_id) do
    Phoenix.PubSub.broadcast!(
      Realtime.PubSub,
      "realtime:operations:invalidate_cache",
      {:invalidate_cache, tenant_id}
    )
  end

  defp apply_repo_fun(arg1, arg2) do
    Realtime.ContextCache.apply_fun(Tenants, arg1, arg2)
  end
end
