defmodule Realtime.Rpc do
  @moduledoc """
  RPC module for Realtime with the intent of standardizing the RPC interface and collect telemetry
  """
  alias Realtime.Telemetry

  @doc """
  Calls external node using :rpc.call/5 and collects telemetry
  """
  @spec call(atom(), atom(), atom(), any(), keyword()) :: any()
  def call(node, mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
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
  @spec enhanced_call(atom(), atom(), atom(), any(), keyword()) :: any()
  def enhanced_call(node, mod, func, args \\ [], opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    {latency, response} = :timer.tc(fn -> :erpc.call(node, mod, func, args, timeout) end)

    Telemetry.execute(
      [:realtime, :rpc],
      %{latency: latency},
      %{
        mod: mod,
        func: func,
        target_node: node,
        origin_node: node()
      }
    )

    response
  end
end
