defmodule Realtime.Rpc do
  @moduledoc """
  RPC module for Realtime with the intent of standardizing the RPC interface and collect telemetry
  """
  alias Realtime.Telemetry
  import Realtime.Logs

  @doc """
  Calls external node using :rpc.call/5 and collects telemetry
  """
  @spec call(atom(), atom(), atom(), any(), keyword()) :: any()
  def call(node, mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))
    {latency, response} = :timer.tc(fn -> :rpc.call(node, mod, func, args, timeout) end)
    tenant = Keyword.get(opts, :tenant, nil)

    Telemetry.execute(
      [:realtime, :tenants, :rpc],
      %{latency: latency},
      %{
        tenant: tenant,
        mod: mod,
        func: func,
        target_node: node,
        origin_node: node()
      }
    )

    response
  end

  @doc """
  Calls external node using :erpc.call/5 and collects telemetry
  """
  @spec enhanced_call(atom(), atom(), atom(), any(), keyword()) :: {:ok, any()} | {:error, any()}
  def enhanced_call(node, mod, func, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))

    with {latency, {status, _} = response} <-
           :timer.tc(fn -> :erpc.call(node, mod, func, args, timeout) end) do
      Telemetry.execute(
        [:realtime, :rpc],
        %{latency: latency, success?: status == :ok},
        %{mod: mod, func: func, target_node: node, origin_node: node()}
      )

      case response do
        {status, _} when status in [:ok, :error] -> response
        _ -> {:error, response}
      end
    end
  catch
    kind, reason ->
      log_error(
        "ErrorOnRpcCall",
        %{target: node, mod: mod, func: func, error: {kind, reason}},
        mod: mod,
        func: func,
        target: node
      )

      {:error, "RPC call error"}
  end
end
