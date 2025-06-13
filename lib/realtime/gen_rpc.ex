defmodule Realtime.GenRpc do
  @moduledoc """
  RPC module for Realtime using :gen_rpc
  """
  use Realtime.Logs

  @default_max_gen_rpc_clients 10

  @type result :: any | {:error, :rpc_error, reason :: any}

  @doc """
  Evaluates apply(mod, func, args) on all nodes

  Options:

  - `:timeout` - timeout for the RPC call, defaults to 5000ms
  - `:tenant_id` - tenant ID for telemetry and logging, defaults to nil
  - `:key` - Optional key to consistently select the same gen_rpc clients
  """
  @spec multicall(module, atom, list(any), keyword()) :: [{node, result}]
  def multicall(mod, func, args, opts \\ []) when is_atom(mod) and is_atom(func) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, default_rpc_timeout())
    tenant_id = Keyword.get(opts, :tenant_id)
    key = Keyword.get(opts, :key, nil)

    nodes = rpc_nodes(Node.list(), key)

    # Here we run the function on all nodes using gen_rpc except the local node
    # This is because gen_rpc does not have a bypass for local node on multicall
    # For the local node we use rpc instead
    local_ref = :rpc.async_call(node(), mod, func, args)

    results =
      nodes
      |> Enum.map(&{&1, :gen_rpc.async_call(&1, mod, func, args)})
      |> Enum.map(fn {node, ref} ->
        result =
          case :gen_rpc.nb_yield(ref, timeout) do
            :timeout -> {:error, :rpc_error, :timeout}
            {:value, {:badrpc, reason}} -> {:error, :rpc_error, reason}
            {:value, {:badtpc, reason}} -> {:error, :rpc_error, reason}
            {:value, result} -> result
          end

        {node, result}
      end)

    results =
      case :rpc.nb_yield(local_ref, timeout) do
        :timeout -> [{node(), {:error, :rpc_error, :timeout}} | results]
        {:value, {:badrpc, reason}} -> [{node(), {:error, :rpc_error, reason}} | results]
        {:value, {:badtpc, reason}} -> [{node(), {:error, :rpc_error, reason}} | results]
        {:value, result} -> [{node(), result} | results]
      end

    Enum.each(results, fn
      {node, {:error, :rpc_error, reason}} ->
        log_error(
          "ErrorOnRpcCall",
          %{target: node, mod: mod, func: func, error: reason},
          project: tenant_id,
          external_id: tenant_id
        )

      _result ->
        :ok
    end)

    results
  end

  @doc """
  Evaluates apply(Module, Function, Args) (apply/3) on the nodes Nodes. No
  response is delivered to the calling process. It returns immediately.
  """
  @spec multicast(module, atom, list(any), keyword()) :: :ok
  def multicast(mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_rpc_timeout())
    key = Keyword.get(opts, :key, nil)
    nodes = rpc_nodes(Node.list(), key)

    # Here we run the function on all nodes except the local one using gen_rpc
    # This is because gen_rpc does not have a bypass for local casts
    :gen_rpc.eval_everywhere(nodes, mod, func, args, timeout)

    spawn(fn -> :erlang.apply(mod, func, args) end)

    :ok
  end

  # Max amount of clients (TCP connections) used by gen_rpc
  defp max_clients(), do: Application.get_env(:realtime, :max_gen_rpc_clients, @default_max_gen_rpc_clients)

  defp rpc_nodes(nodes, key), do: Enum.map(nodes, &rpc_node(&1, key))

  # Tag the node with a random number from 1 to max_clients
  # This ensures that we don't use the same client/tcp connection for this node
  defp rpc_node(node, nil), do: {node, :rand.uniform(max_clients())}

  # Tag the node with a random number from 1 to max_clients
  # Using phash2 to ensure the same key and the same client per node
  defp rpc_node(node, key), do: {node, :erlang.phash2(key, max_clients()) + 1}

  defp default_rpc_timeout, do: Application.get_env(:realtime, :rpc_timeout, 5_000)
end
