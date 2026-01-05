defmodule Realtime.UsersCounter do
  @moduledoc """
  Counts of connected clients for a tenant across the whole cluster or for a single node.
  """
  require Logger

  @doc """
  Adds a RealtimeChannel pid to the `:users` scope for a tenant so we can keep track of all connected clients for a tenant.
  """
  @spec add(pid(), String.t()) :: :ok
  def add(pid, tenant_id) when is_pid(pid) and is_binary(tenant_id) do
    beacon_join(pid, tenant_id)
    tenant_id |> scope() |> :syn.join(tenant_id, pid)
  end

  defp beacon_join(pid, tenant_id) do
    :ok = Beacon.join(:users, tenant_id, pid)
  rescue
    _ -> Logger.error("Failed to join Beacon users scope for tenant #{tenant_id}")
  end

  @doc """
  Returns the count of all connected clients for a tenant for the cluster.
  """
  @spec tenant_users(String.t()) :: non_neg_integer()
  def tenant_users(tenant_id), do: tenant_id |> scope() |> :syn.member_count(tenant_id)

  @doc """
  Returns the count of all connected clients for a tenant for a single node.
  """
  @spec tenant_users(atom, String.t()) :: non_neg_integer()
  def tenant_users(node_name, tenant_id), do: tenant_id |> scope() |> :syn.member_count(tenant_id, node_name)

  @count_all_nodes_spec [
    {
      # Match the tuple structure, capture group_name
      {{:"$1", :_}, :_, :_, :_, :_},
      # No guards
      [],
      # Return only the group_name
      [:"$1"]
    }
  ]

  @doc """
  Returns the counts of all connected clients for all tenants for the cluster.
  """
  @spec tenant_counts() :: %{String.t() => non_neg_integer()}
  def tenant_counts() do
    scopes()
    |> Stream.flat_map(fn scope ->
      :syn_backbone.get_table_name(:syn_pg_by_name, scope)
      |> :ets.select(@count_all_nodes_spec)
    end)
    |> Enum.frequencies()
  end

  @doc """
  Returns the counts of all connected clients for all tenants for a single node.
  """
  @spec tenant_counts(node) :: %{String.t() => non_neg_integer()}
  def tenant_counts(node) do
    count_single_node_spec = [
      {
        # Match the tuple structure with specific node, capture group_name
        {{:"$1", :_}, :_, :_, :_, node},
        # No guards
        [],
        # Return only the group_name
        [:"$1"]
      }
    ]

    scopes()
    |> Stream.flat_map(fn scope ->
      :syn_backbone.get_table_name(:syn_pg_by_name, scope)
      |> :ets.select(count_single_node_spec)
    end)
    |> Enum.frequencies()
  end

  @doc """
  Returns the scope for a given tenant id.
  """
  @spec scope(String.t()) :: atom()
  def scope(tenant_id) do
    shards = Application.fetch_env!(:realtime, :users_scope_shards)
    shard = :erlang.phash2(tenant_id, shards)
    :"users_#{shard}"
  end

  def scopes() do
    shards = Application.fetch_env!(:realtime, :users_scope_shards)
    Enum.map(0..(shards - 1), fn shard -> :"users_#{shard}" end)
  end
end
