defmodule Multiplayer.UsersCounter do
  require Logger

  def add(pid, tenant) do
    :syn.join(:users, tenant, pid)
  end

  def tenant_users(tenant) do
    :syn.member_count(:users, tenant)
  end

  def tenant_users(node_name, tenant) do
    :syn.member_count(:users, tenant, node_name)
  end
end
