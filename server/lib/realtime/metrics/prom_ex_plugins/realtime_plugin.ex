defmodule Realtime.Metrics.PromEx.Plugins.Realtime do
  use PromEx.Plugin

  @event_prefix [:realtime, :prom_ex, :plugin, :socket]

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :realtime_socket_event_metrics,
      [
        last_value(
          [:realtime, :active, :websocket, :connection, :total],
          event_name: socket_event(),
          measurement: :active_socket_total,
          description: "The total number of active websocket connections."
        ),
        last_value(
          [:realtime, :active, :websocket, :topic, :total],
          event_name: channel_event(),
          measurement: :active_channel_total,
          description: "The total number of active topic subscriptions."
        )
      ]
    )
  end

  def socket_event, do: @event_prefix ++ [:connection]
  def channel_event, do: @event_prefix ++ [:channel]
end
