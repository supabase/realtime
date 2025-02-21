defmodule Realtime.Rpc do
  @moduledoc """
  RPC module for Realtime with the intent of standardizing the RPC interface and collect telemetry
  """
  import Realtime.Logs
  alias Realtime.Telemetry

  @doc """
  Calls external node using :rpc.call/5 and collects telemetry
  """
  @spec call(atom(), atom(), atom(), any(), keyword()) :: any()
  def call(node, mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))
    {latency, response} = :timer.tc(fn -> :rpc.call(node, mod, func, args, timeout) end)

    Telemetry.execute(
      [:realtime, :rpc],
      %{latency: latency},
      %{mod: mod, func: func, target_node: node, origin_node: node()}
    )

    response
  end

  @doc """
  Calls external node using :erpc.call/5 and collects telemetry
  """
  @spec enhanced_call(atom(), atom(), atom(), any(), keyword()) :: {:ok, any()} | {:error, any()}
  def enhanced_call(node, mod, func, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))

    with {latency, response} <-
           :timer.tc(fn -> :erpc.call(node, mod, func, args, timeout) end) do
      case response do
        {:ok, _} ->
          Telemetry.execute(
            [:realtime, :rpc],
            %{latency: latency, success?: true},
            %{mod: mod, func: func, target_node: node, origin_node: node()}
          )

          response

        {:error, response} ->
          Telemetry.execute(
            [:realtime, :rpc],
            %{latency: latency, success?: false},
            %{mod: mod, func: func, target_node: node, origin_node: node()}
          )

          {:error, response}
      end
    end
  catch
    kind, reason ->
      Telemetry.execute(
        [:realtime, :rpc],
        %{latency: 0, success?: false},
        %{mod: mod, func: func, target_node: node, origin_node: node()}
      )

      log_error(
        "ErrorOnRpcCall",
        %{target: node, mod: mod, func: func, error: {kind, reason}},
        mod: mod,
        func: func,
        target: node
      )

      case reason do
        {:erpc, :timeout} -> {:error, :rpc_error, :timeout}
        {:exception, error, _} -> {:error, :rpc_error, error}
        _ -> {:error, reason}
      end
  end
end
