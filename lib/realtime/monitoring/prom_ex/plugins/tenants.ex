defmodule Realtime.PromEx.Plugins.Tenants do
  @moduledoc false

  use PromEx.Plugin
  require Logger

  @event_connected [:prom_ex, :plugin, :realtime, :tenants, :connected]

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate)

    [
      metrics(poll_rate)
    ]
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
