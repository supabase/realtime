defmodule Realtime.ErlSysMon do
  @moduledoc """
  Logs Erlang System Monitor events.
  """

  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(_args) do
    :erlang.system_monitor(self(), [
      :busy_dist_port,
      :busy_port,
      {:long_gc, 250},
      {:long_schedule, 100}
    ])

    {:ok, []}
  end

  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} message: " <> inspect(msg))

    {:noreply, state}
  end
end
