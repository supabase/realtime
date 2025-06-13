defmodule Realtime.GenRpc do
  @moduledoc """
  RPC module for Realtime using :gen_rpc
  """

  @default_max_gen_rpc_clients 10

  @doc """
  Evaluates apply(Module, Function, Args) (apply/3) on the nodes Nodes. No
  response is delivered to the calling process. It returns immediately.
  """
  @spec multicast(module, atom, list(any), keyword()) :: :ok
  def multicast(mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_rpc_timeout())
    nodes = rpc_nodes(Node.list())

    # Here we run the function on all nodes except the local one using gen_rpc
    # This is because gen_rpc does not have a bypass for local casts
    :gen_rpc.eval_everywhere(nodes, mod, func, args, timeout)

    spawn(fn -> :erlang.apply(mod, func, args) end)

    :ok
  end

  # Max amount of clients (TCP connections) used by gen_rpc
  defp max_clients(), do: Application.get_env(:realtime, :max_gen_rpc_clients, @default_max_gen_rpc_clients)

  defp rpc_nodes(nodes), do: Enum.map(nodes, &rpc_node/1)

  # Tag the node with a random number from 1 to max_clients
  # This ensures that we balance requests sent to this node
  defp rpc_node(node) when is_atom(node) do
    {node, :rand.uniform(max_clients())}
  end

  defp default_rpc_timeout, do: Application.get_env(:realtime, :rpc_timeout, 5_000)
end
