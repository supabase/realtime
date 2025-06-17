defmodule Realtime.Tenants.Cache do
  @moduledoc """
  Cache for Tenants.
  """
  require Cachex.Spec
  require Logger

  alias Realtime.Tenants

  def child_spec(_) do
    tenant_cache_expiration = Application.get_env(:realtime, :tenant_cache_expiration)

    %{
      id: __MODULE__,
      start: {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: tenant_cache_expiration)]]}
    }
  end

  def get_tenant_by_external_id(keyword), do: apply_repo_fun(__ENV__.function, [keyword])

  @doc """
  Invalidates the cache for a tenant in the local node
  """
  def invalidate_tenant_cache(tenant_id), do: Cachex.del(__MODULE__, {{:get_tenant_by_external_id, 1}, [tenant_id]})

  @doc """
  Broadcasts a message to invalidate the tenant cache to all connected nodes
  """
  @spec distributed_invalidate_tenant_cache(String.t()) :: boolean()
  def distributed_invalidate_tenant_cache(tenant_id) when is_binary(tenant_id) do
    nodes = [Node.self() | Node.list()]
    results = :erpc.multicall(nodes, __MODULE__, :invalidate_tenant_cache, [tenant_id], 1000)

    results
    |> Enum.map(fn
      {res, _} ->
        res

      exception ->
        Logger.error("Failed to invalidate tenant cache: #{inspect(exception)}")
        :error
    end)
    |> Enum.all?(&(&1 == :ok))
  end

  defp apply_repo_fun(arg1, arg2), do: Realtime.ContextCache.apply_fun(Tenants, arg1, arg2)
end
