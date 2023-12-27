defmodule Realtime.Rpc do
  @moduledoc """
  RPC module for Realtime with the intent of standardizing the RPC interface and collect telemetry
  """
  alias Realtime.Telemetry

  @doc """
  Calls external node using :rpc.call/5 and collects telemetry
  """
  def call(node, mod, func, opts \\ [], timeout \\ 15000) do
    {latency, response} = :timer.tc(fn -> :rpc.call(node, mod, func, opts, timeout) end)
    tenant = Keyword.get(opts, :tenant, nil)

    Telemetry.execute([:realtime, :tenants, :rpc, :calls], %{latency: latency, tenant: tenant}, %{
      mod: mod,
      func: func,
      target_node: node,
      origin_node: node()
    })

    response
  rescue
    _ ->
      tenant = Keyword.get(opts, :tenant, nil)

      Telemetry.execute([:erpc, :calls], %{tenant: tenant, latency: timeout}, %{
        mod: mod,
        func: func,
        target_node: node,
        origin_node: node()
      })
  end

  @doc """
  Calls external node using :erpc.call/5 and collects telemetry
  """
  def ecall(node, mod, func, opts \\ [], timeout \\ 15000) do
    {latency, response} = :timer.tc(fn -> :erpc.call(node, mod, func, opts, timeout) end)
    tenant = Keyword.get(opts, :tenant, nil)

    Telemetry.execute(
      [:realtime, :tenants, :erpc, :calls],
      %{latency: latency, tenant: tenant},
      %{
        mod: mod,
        func: func,
        target_node: node,
        origin_node: node()
      }
    )

    response
  rescue
    _ ->
      tenant = Keyword.get(opts, :tenant, nil)

      Telemetry.execute([:erpc, :calls], %{tenant: tenant, latency: timeout}, %{
        mod: mod,
        func: func,
        target_node: node,
        origin_node: node()
      })
  end
end
