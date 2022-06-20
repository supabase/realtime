defmodule Realtime.PromEx.Plugins.OsMon do
  use PromEx.Plugin
  require Logger
  alias Realtime.OsMetrics

  @event_ram_usage [:prom_ex, :plugin, :osmon, :ram_usage]
  @event_cpu_util [:prom_ex, :plugin, :osmon, :cpu_util]
  @event_cpu_la [:prom_ex, :plugin, :osmon, :cpu_avg1]

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      metrics(poll_rate)
    ]
  end

  defp metrics(poll_rate) do
    Polling.build(
      :realtime_osmon_events,
      poll_rate,
      {__MODULE__, :execute_metrics, []},
      [
        last_value(
          [:realtime, :prom_ex, :osmon, :ram_usage],
          event_name: @event_ram_usage,
          description: "The total percentage usage of operative memory.",
          measurement: :ram,
          tags: [:node, :region]
        ),
        last_value(
          [:realtime, :prom_ex, :osmon, :cpu_util],
          event_name: @event_cpu_util,
          description:
            "The sum of the percentage shares of the CPU cycles spent in all busy processor states in average on all CPUs.",
          measurement: :cpu,
          tags: [:node, :region]
        ),
        last_value(
          [:realtime, :prom_ex, :osmon, :cpu_avg1],
          event_name: @event_cpu_la,
          description: "The average system load in the last minute.",
          measurement: :avg1,
          tags: [:node, :region]
        ),
        last_value(
          [:realtime, :prom_ex, :osmon, :cpu_avg5],
          event_name: @event_cpu_la,
          description: "The average system load in the last five minutes.",
          measurement: :avg5,
          tags: [:node, :region]
        ),
        last_value(
          [:realtime, :prom_ex, :osmon, :cpu_avg15],
          event_name: @event_cpu_la,
          description: "The average system load in the last 15 minutes.",
          measurement: :avg15,
          tags: [:node, :region]
        )
      ]
    )
  end

  def execute_metrics() do
    execute_metrics(@event_ram_usage, %{ram: OsMetrics.ram_usage()})
    execute_metrics(@event_cpu_util, %{cpu: OsMetrics.cpu_util()})
    execute_metrics(@event_cpu_la, OsMetrics.cpu_la())
  end

  defp execute_metrics(event, metrics) do
    :telemetry.execute(event, metrics, default_tags())
  end

  defp default_tags() do
    %{
      node: node(),
      region: System.get_env("FLY_REGION")
    }
  end
end
