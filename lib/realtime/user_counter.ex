defmodule Realtime.UsersCounter do
  @moduledoc false
  require Logger

  @spec add(pid(), String.t()) :: :ok
  def add(pid, tenant) do
    :syn.join(:users, tenant, pid)
  end

  @spec tenant_users(String.t()) :: non_neg_integer()
  def tenant_users(tenant) do
    :syn.member_count(:users, tenant)
  end

  @spec tenant_users(atom, String.t()) :: non_neg_integer()
  def tenant_users(node_name, tenant) do
    :syn.member_count(:users, tenant, node_name)
  end
end
