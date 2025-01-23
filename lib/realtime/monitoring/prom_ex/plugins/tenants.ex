defmodule Realtime.PromEx.Plugins.Tenants do
  @moduledoc false

  use PromEx.Plugin

  alias PromEx.MetricTypes.Event

  require Logger

  @event_connected [:prom_ex, :plugin, :realtime, :tenants, :connected]

  @impl true
  def event_metrics(opts) do
    rpc_metrics(opts)
  end

  defp rpc_metrics(_opts) do
    Event.build(:realtime, [
      distribution(
        [:realtime, :rpc],
        event_name: [:realtime, :rpc],
        description: "Latency of rpc calls triggered by a tenant action",
        measurement: :latency,
        unit: {:microsecond, :millisecond},
        reporter_options: [buckets: [10, 50, 250, 1500, 15_000]]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)

    [metrics(poll_rate)]
  end

  defp metrics(poll_rate) do
    Polling.build(
      :realtime_tenants_events,
      poll_rate,
      {__MODULE__, :execute_metrics, []},
      [
        last_value(
          [:realtime, :tenants, :connected],
          event_name: @event_connected,
          description: "The total count of connected tenants.",
          measurement: :connected
        )
      ]
    )
  end

  def execute_metrics() do
    connected =
      if Enum.member?(:syn.node_scopes(), Extensions.PostgresCdcRls) do
        :syn.local_registry_count(Extensions.PostgresCdcRls)
      else
        -1
      end

    execute_metrics(@event_connected, %{
      connected: connected
    })
  end

  defp execute_metrics(event, metrics) do
    :telemetry.execute(event, metrics, %{})
  end
end
