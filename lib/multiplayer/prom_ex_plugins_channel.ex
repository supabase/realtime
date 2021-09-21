defmodule Multiplayer.PromEx.Plugins.Channels do
  use PromEx.Plugin
  require Logger
  alias TelemetryMetricsPrometheus.Core

  @sessions_event_cluster [:prom_ex, :plugin, :multiplayer, :sessions_cluster]
  @topics_event_cluster [:prom_ex, :plugin, :multiplayer, :topics_cluster]
  @disconnected_cluster_event [:prom_ex, :plugin, :multiplayer, :disconnected_cluster]
  @joined_cluster_event [:prom_ex, :plugin, :multiplayer, :joined_cluster]
  @disconnected_event [:prom_ex, :plugin, :multiplayer, :disconnected]
  @msg_sent_event [:prom_ex, :plugin, :multiplayer, :msg_sent]
  @msg_sent_cluster_event [:prom_ex, :plugin, :multiplayer, :msg_sent_cluster]

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
        ),
        counter(
          [:multiplayer, :realtime_channel, :msg_sent],
          event_name: @msg_sent_event,
          description: "Total realtime_channel messages sent"
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
          [:multiplayer, :realtime_channel, :sessions_cluster],
          event_name: @sessions_event_cluster,
          description: "Total realtime_channel sessions",
          measurement: :online
        ),
        last_value(
          [:multiplayer, :realtime_channel, :topics_cluster],
          event_name: @topics_event_cluster,
          description: "Total realtime_channel topics in all cluster",
          measurement: :topics
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
        ),
        last_value(
          [:multiplayer, :realtime_channel, :msg_sent_cluster],
          event_name: @msg_sent_cluster_event,
          description: "Total realtime_channel messages sent in all cluster",
          measurement: :msg_sent
        )
      ]
    )
  end

  def execute_channel_metrics() do
    :telemetry.execute(@sessions_event_cluster, %{online: online()}, %{})
    :telemetry.execute(@topics_event_cluster, %{topics: topics()}, %{})
    :telemetry.execute(@disconnected_cluster_event, %{disconnected: disconnected()}, %{})
    :telemetry.execute(@joined_cluster_event, %{joined: joined()}, %{})
    :telemetry.execute(@msg_sent_cluster_event, %{msg_sent: msg_sent()}, %{})
  end

  def online() do
    remote_online = remote_acc(Node.list(), :local_online)
    local_online() + remote_online
  end

  def local_online() do
    Registry.count(Multiplayer.Registry.Unique)
  end

  def topics() do
    remote_topics = remote_acc(Node.list(), :local_topics)
    local_topics() + remote_topics
  end

  def local_topics() do
    Registry.count_match(Multiplayer.Registry, "topics", {:_, :_, :_})
  end

  def msg_sent() do
    remote_msg_sent = remote_acc(Node.list(), :local_msg_sent)
    local_msg_sent() + remote_msg_sent
  end

  def local_msg_sent() do
    config = Core.Registry.config(Multiplayer.PromEx.Metrics)
    ts = Core.Aggregator.get_time_series(config.aggregates_table_id)

    case ts[[:multiplayer, :realtime_channel, :msg_sent]] do
      [{_, count}] when is_integer(count) -> count
      _ -> 0
    end
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

        val ->
          acc + val
      end
    end)
  end
end
