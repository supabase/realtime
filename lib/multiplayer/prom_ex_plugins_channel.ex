defmodule Multiplayer.PromEx.Plugins.Channels do
  use PromEx.Plugin

  @channel_event [:prom_ex, :plugin, :multiplayer, :channels]

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      channel_metrics(poll_rate)
    ]
  end

  defp channel_metrics(poll_rate) do
    Polling.build(
      :multiplayer_channel_polling_events,
      poll_rate,
      {__MODULE__, :execute_channel_metrics, []},
      [
        last_value(
          [:multiplayer, :total, :ws, :users],
          event_name: @channel_event,
          description: "Total WS users",
          measurement: :online
        )
      ]
    )
  end

  def execute_channel_metrics do
    :telemetry.execute(@channel_event, %{online: online(), topics: 200, scopes: 12}, %{})
  end

  def online() do
    :syn.get_members("channels") |> length
  end

end
