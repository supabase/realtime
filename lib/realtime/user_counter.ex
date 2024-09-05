defmodule Realtime.UsersCounter do
  @moduledoc """
  Counts of connected clients for a tenant across the whole cluster or for a single node.
  """
  require Logger

  @doc """
  Adds a RealtimeChannel pid to the `:users` scope for a tenant so we can keep track of all connected clients for a tenant.
  """

  @spec add(pid(), String.t()) :: :ok
  def add(pid, tenant) do
    :syn.join(:users, tenant, pid)
  end

  @doc """
  Returns the count of all connected clients for a tenant for the cluster.
  """

  @spec tenant_users(String.t()) :: non_neg_integer()
  def tenant_users(tenant) do
    :syn.member_count(:users, tenant)
  end

  @doc """
  Returns the count of all connected clients for a tenant for a single node.
  """

  @spec tenant_users(atom, String.t()) :: non_neg_integer()
  def tenant_users(node_name, tenant) do
    :syn.member_count(:users, tenant, node_name)
  end
end
