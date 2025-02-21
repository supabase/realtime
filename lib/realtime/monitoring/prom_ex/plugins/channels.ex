defmodule Realtime.PromEx.Plugins.Channels do
  @moduledoc """
  Realtime channels monitoring plugin for PromEx
  """
  use PromEx.Plugin
  require Logger

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime, [
      counter(
        [:realtime, :channel, :error],
        event_name: [:realtime, :channel, :error],
        measurement: :code,
        tags: [:code],
        description: "Count of errors in the Realtime channels initialization"
      )
    ])
  end
end
