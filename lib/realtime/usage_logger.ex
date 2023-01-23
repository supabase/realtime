defmodule Realtime.UsageLogger do
  @moduledoc """
  Polls certain metrics and logs them for billing purposes.
  """

  use GenServer

  @poll_every 60_000

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    {:ok, []}
  end

  def handle_info(:poll, state) do
    poll()
    {:noreply, state}
  end

  defp poll(every \\ @poll_every) do
    Process.send(self(), :poll, every)
  end
end
