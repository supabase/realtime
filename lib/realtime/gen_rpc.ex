defmodule Realtime.GenRpc do
  @moduledoc """
  RPC module for Realtime using :gen_rpc

  :max_gen_rpc_clients is the maximum number of clients (TCP connections) used by gen_rpc
  between two nodes
  """
  use Realtime.Logs
  alias Realtime.Telemetry

  @type result :: any | {:error, :rpc_error, reason :: any}

  @doc """
  Broadcasts the message `msg` asynchronously to the registered process `name` on the specified `nodes`.

  Options:

  - `:key` - Optional key to consistently select the same gen_rpc clients to guarantee message order between nodes
  """
  @spec abcast([node], atom, any, keyword()) :: :ok
  def abcast(nodes, name, msg, opts) when is_list(nodes) and is_atom(name) and is_list(opts) do
    key = Keyword.get(opts, :key, nil)
    nodes = rpc_nodes(nodes, key)

    :gen_rpc.abcast(nodes, name, msg)
    :ok
  end

  @doc """
  Fire and forget apply(mod, func, args) on all nodes

  Options:

  - `:key` - Optional key to consistently select the same gen_rpc clients to guarantee message order between nodes
  """
  @spec multicast(module, atom, list(any), keyword()) :: :ok
  def multicast(mod, func, args, opts \\ []) when is_atom(mod) and is_atom(func) and is_list(args) and is_list(opts) do
    key = Keyword.get(opts, :key, nil)

    nodes = rpc_nodes(Node.list(), key)

    # Use erpc for the local node because :gen_rpc tries to connect with the local node
    :ok = :erpc.cast(Node.self(), mod, func, args)
    :gen_rpc.eval_everywhere(nodes, mod, func, args)
    :ok
  end

  @doc """
  Calls node to apply(mod, func, args)

  Options:

  - `:key` - Optional key to consistently select the same gen_rpc clients to guarantee message order between nodes
  - `:tenant_id` - Tenant ID for telemetry and logging, defaults to nil
  - `:timeout` - timeout in milliseconds for the RPC call, defaults to 5000ms
  """
  @spec call(node, module, atom, list(any), keyword()) :: result
  def call(node, mod, func, args, opts)
      when is_atom(node) and is_atom(mod) and is_atom(func) and is_list(args) and is_list(opts) do
    if node == node() or node in Node.list() do
      do_call(node, mod, func, args, opts)
    else
      tenant_id = Keyword.get(opts, :tenant_id)

      log_error(
        "ErrorOnRpcCall",
        %{target: node, mod: mod, func: func, error: :badnode},
        project: tenant_id,
        external_id: tenant_id
      )

      {:error, :rpc_error, :badnode}
    end
  end

  defp do_call(node, mod, func, args, opts) do
    timeout = Keyword.get(opts, :timeout, default_rpc_timeout())
    tenant_id = Keyword.get(opts, :tenant_id)
    key = Keyword.get(opts, :key, nil)

    node_key = rpc_node(node, key)
    {latency, response} = :timer.tc(fn -> :gen_rpc.call(node_key, mod, func, args, timeout) end)

    case response do
      {:badrpc, reason} ->
        log_error(
          "ErrorOnRpcCall",
          %{target: node, mod: mod, func: func, error: reason},
          project: tenant_id,
          external_id: tenant_id
        )

        telemetry_failure(node, latency, tenant_id)

        {:error, :rpc_error, reason}

      {:error, _} ->
        telemetry_failure(node, latency, tenant_id)
        response

      _ ->
        telemetry_success(node, latency, tenant_id)
        response
    end
  end

  # Not using :gen_rpc.multicall here because we can't see the actual results on errors

  @doc """
  Evaluates apply(mod, func, args) on all nodes

  Options:

  - `:timeout` - timeout for the RPC call, defaults to 5000ms
  - `:tenant_id` - tenant ID for telemetry and logging, defaults to nil
  - `:key` - Optional key to consistently select the same gen_rpc clients to guarantee message order between nodes
  """
  @spec multicall(module, atom, list(any), keyword()) :: [{node, result}]
  def multicall(mod, func, args, opts \\ []) when is_atom(mod) and is_atom(func) and is_list(args) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, default_rpc_timeout())
    tenant_id = Keyword.get(opts, :tenant_id)
    key = Keyword.get(opts, :key, nil)

    nodes = rpc_nodes([node() | Node.list()], key)

    # Latency here is the amount of time that it takes for this node to gather the result.
    # If one node takes a while to reply the remaining calls will have at least the latency reported by this node
    # Example:
    # Node A, B and C receive the calls in this order
    # Node A takes 500ms to return on nb_yield
    # Node B and C will report at least 500ms to return regardless how long it took for them to actually reply back
    results =
      nodes
      |> Enum.map(&{&1, :erlang.monotonic_time(), async_call(&1, mod, func, args)})
      |> Enum.map(fn {{node, _key}, start_time, ref} ->
        result =
          case nb_yield(node, ref, timeout) do
            :timeout -> {:error, :rpc_error, :timeout}
            {:value, {:badrpc, reason}} -> {:error, :rpc_error, reason}
            {:value, result} -> result
          end

        end_time = :erlang.monotonic_time()
        latency = :erlang.convert_time_unit(end_time - start_time, :native, :microsecond)
        {node, latency, result}
      end)

    Enum.map(results, fn
      {node, latency, {:error, :rpc_error, reason} = result} ->
        log_error(
          "ErrorOnRpcCall",
          %{target: node, mod: mod, func: func, error: reason},
          project: tenant_id,
          external_id: tenant_id
        )

        telemetry_failure(node, latency, tenant_id)
        {node, result}

      {node, latency, {:ok, _} = result} ->
        telemetry_success(node, latency, tenant_id)
        {node, result}

      {node, latency, result} ->
        telemetry_failure(node, latency, tenant_id)
        {node, result}
    end)
  end

  defp telemetry_success(node, latency, tenant_id) do
    Telemetry.execute(
      [:realtime, :rpc],
      %{latency: latency},
      %{origin_node: node(), target_node: node, success: true, tenant: tenant_id, mechanism: :gen_rpc}
    )
  end

  defp telemetry_failure(node, latency, tenant_id) do
    Telemetry.execute(
      [:realtime, :rpc],
      %{latency: latency},
      %{origin_node: node(), target_node: node, success: false, tenant: tenant_id, mechanism: :gen_rpc}
    )
  end

  # Max amount of clients (TCP connections) used by gen_rpc
  defp max_clients(), do: Application.fetch_env!(:realtime, :max_gen_rpc_clients)

  defp rpc_nodes(nodes, key), do: Enum.map(nodes, &rpc_node(&1, key))

  # Tag the node with a random number from 1 to max_clients
  # This ensures that we don't use the same client/tcp connection for this node
  defp rpc_node(node, nil), do: {node, :rand.uniform(max_clients())}

  # Tag the node with a random number from 1 to max_clients
  # Using phash2 to ensure the same key and the same client per node
  defp rpc_node(node, key), do: {node, :erlang.phash2(key, max_clients()) + 1}

  defp default_rpc_timeout, do: Application.get_env(:realtime, :rpc_timeout, 5_000)

  # Here we run the async_call on all nodes using gen_rpc except the local node
  # This is because gen_rpc does not have a bypass for local node on multicall
  # For the local node we use rpc instead
  defp async_call({node, _}, mod, func, args) when node == node(), do: :rpc.async_call(node, mod, func, args)
  defp async_call(node, mod, func, args), do: :gen_rpc.async_call(node, mod, func, args)

  defp nb_yield(node, ref, timeout) when node == node(), do: :rpc.nb_yield(ref, timeout)
  defp nb_yield(_node, ref, timeout), do: :gen_rpc.nb_yield(ref, timeout)
end
