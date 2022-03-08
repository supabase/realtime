defmodule Multiplayer.UsersCounter do
  use GenServer
  require Logger

  def add(pid, tenant_id) do
    :syn.join(:users, {node(), tenant_id}, pid)
    new_count = :syn.local_members(:users, {node(), tenant_id}) |> Enum.count()
    :syn.register(:users, {node(), tenant_id}, self(), count: new_count)
  end

  def tenant_users(tenant_id) do
    Enum.reduce(Node.list(), tenant_users(node(), tenant_id), fn
      node_name, acc ->
        acc + tenant_users(node_name, tenant_id)
    end)
  end

  def tenant_users(node_name, tenant_id) do
    case :syn.lookup(:users, {node_name, tenant_id}) do
      :undefined -> 0
      {_, [count: val]} -> val
    end
  end
end
