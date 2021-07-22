defmodule Multiplayer.PromEx.Plugins.Channels do
  use PromEx.Plugin
  require Logger
  alias TelemetryMetricsPrometheus.Core

  @sessions_event [:prom_ex, :plugin, :multiplayer, :realtime_channel]
  @disconnected_cluster_event [:prom_ex, :plugin, :multiplayer, :disconnected_cluster]
  @joined_cluster_event [:prom_ex, :plugin, :multiplayer, :joined_cluster]
  @disconnected_event [:prom_ex, :plugin, :multiplayer, :disconnected]

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)
    [
      channel_metrics(poll_rate)
    ]
  end

  @impl true
  def event_metrics(opts) do
    Event.build(
      :multiplayer_event_metrics,
      [
        counter(
          [:multiplayer, :realtime_channel, :disconnected],
          event_name: @disconnected_event,
          description: "Total realtime_channel disconnected"
        )
      ]
    )
  end

  defp channel_metrics(poll_rate) do
    Polling.build(
      :multiplayer_channel_polling_events,
      poll_rate,
      {__MODULE__, :execute_channel_metrics, []},
      [
        last_value(
          [:multiplayer, :realtime_channel, :sessions],
          event_name: @sessions_event,
          description: "Total realtime_channel sessions",
          measurement: :online
        ),
        last_value(
          [:multiplayer, :realtime_channel, :disconnected_cluster],
          event_name: @disconnected_cluster_event,
          description: "Total realtime_channel disconnected in all cluster",
          measurement: :disconnected
        ),
        last_value(
          [:multiplayer, :realtime_channel, :joined_cluster],
          event_name: @joined_cluster_event,
          description: "Total realtime_channel joined in all cluster",
          measurement: :joined
        )
      ]
    )
  end

  def execute_channel_metrics() do
    :telemetry.execute(@sessions_event, %{online: online()}, %{})
    :telemetry.execute(@disconnected_cluster_event, %{disconnected: disconnected()}, %{})
    :telemetry.execute(@joined_cluster_event, %{joined: joined()}, %{})
  end

  def online() do
    remote_online = remote_acc(Node.list(), :local_online)
    local_online() + remote_online
  end

  def local_online() do
    Registry.count_match(Multiplayer.Registry, "channels", {:_, :_, :_})
  end

  def joined() do
    remote_joined = remote_acc(Node.list(), :local_joined)
    local_joined() + remote_joined
  end

  def local_joined() do
    config = Core.Registry.config(Multiplayer.PromEx.Metrics)
    ts = Core.Aggregator.get_time_series(config.aggregates_table_id)
    case ts[[:multiplayer, :prom_ex, :phoenix, :channel, :joined, :total]] do
      [{_, count}] when is_integer(count) -> count
      _ -> 0
    end
  end

  def disconnected() do
    remote_disconnected = remote_acc(Node.list(), :local_disconnected)
    local_disconnected() + remote_disconnected
  end

  def local_disconnected() do
    config = Core.Registry.config(Multiplayer.PromEx.Metrics)
    ts = Core.Aggregator.get_time_series(config.aggregates_table_id)
    case ts[[:multiplayer, :realtime_channel, :disconnected]] do
      [{_, count}] when is_integer(count) -> count
      _ -> 0
    end
  end

  def remote_acc(nodes, func_name) when is_atom(func_name) do
    Enum.reduce(nodes, 0, fn remote_node, acc ->
      case :rpc.call(remote_node, __MODULE__, func_name, []) do
        {:badrpc, Reason} ->
          Logger.error("Node down, node: " <> inspect(remote_node))
          0
        val -> acc + val
      end
    end)
  end

end
