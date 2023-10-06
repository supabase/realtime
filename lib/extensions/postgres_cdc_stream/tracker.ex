defmodule Extensions.PostgresCdcStream.Tracker do
  @moduledoc """
  Tracks the state of the CDC stream and broadcasts a message to the channel
  when the stream is down.
  """
  use Phoenix.Tracker
  require Logger

  alias RealtimeWeb.Endpoint

  def start_link(opts) do
    pool_opts = [
      name: __MODULE__,
      pubsub_server: Realtime.PubSub,
      pool_size: 5
    ]

    opts = Keyword.merge(pool_opts, opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  def init(opts) do
    server = Keyword.fetch!(opts, :pubsub_server)
    {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
  end

  def handle_diff(diff, state) do
    for {_topic, {_joins, leaves}} <- diff do
      for {id, _meta} <- leaves do
        Endpoint.local_broadcast(
          "postgres_cdc:" <> id,
          "postgres_cdc_down",
          nil
        )
      end
    end

    {:ok, state}
  end
end
