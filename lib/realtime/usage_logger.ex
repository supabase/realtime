defmodule Realtime.UsageLogger do
  @moduledoc """
  Polls certain metrics and logs them for billing purposes.
  """

  require Logger

  use GenServer

  @poll_every 60_000

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    :telemetry.attach(
      <<"usage-logger">>,
      [:realtime, :limit, :limited],
      &Realtime.UsageLogger.handle_event/4,
      []
    )

    {:ok, []}
  end

  def handle_event([:realtime, :limit, :limited], measurements, metadata, _config) do
    Logger.info(
      "[#{metadata.request_path}] #{metadata.status_code} sent in #{measurements.latency}"
    )
  end

  def handle_info(:poll, state) do
    poll()
    {:noreply, state}
  end

  defp poll(every \\ @poll_every) do
    Process.send(self(), :poll, every)
  end
end
