defmodule Realtime.UsersCounter do
  @moduledoc """
  Counts of connected clients for a tenant across the whole cluster or for a single node.
  """
  require Logger

  @doc """
  Adds a RealtimeChannel pid to the `:users` scope for a tenant so we can keep track of all connected clients for a tenant.
  """
  @spec add(pid(), String.t()) :: :ok
  def add(pid, tenant_id), do: tenant_id |> scope() |> :syn.join(tenant_id, pid)

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

  @doc """
  Returns the scope for a given tenant id.
  """
  @spec scope(String.t()) :: atom()
  def scope(tenant_id) do
    shards = Application.get_env(:realtime, :users_scope_shards)
    shard = :erlang.phash2(tenant_id, shards)
    :"users_#{shard}"
  end

  def scopes() do
    shards = Application.get_env(:realtime, :users_scope_shards)
    Enum.map(0..(shards - 1), fn shard -> :"users_#{shard}" end)
  end
end
