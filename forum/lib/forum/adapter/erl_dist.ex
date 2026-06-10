defmodule Forum.Adapter.ErlDist do
  @moduledoc false

  import Kernel, except: [send: 2]

  @behaviour Forum.Adapter

  @impl true
  def register(scope) do
    Process.register(self(), Forum.Supervisor.name(scope))
    :ok
  end

  @impl true
  def broadcast(scope, message) do
    name = Forum.Supervisor.name(scope)
    Enum.each(Node.list(), fn node -> :erlang.send({name, node}, message, [:noconnect]) end)
  end

  @impl true
  def broadcast(scope, nodes, message) do
    name = Forum.Supervisor.name(scope)
    Enum.each(nodes, fn node -> :erlang.send({name, node}, message, [:noconnect]) end)
  end

  @impl true
  def send(scope, node, message) do
    :erlang.send({Forum.Supervisor.name(scope), node}, message, [:noconnect])
  end
end
