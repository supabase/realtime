defmodule Realtime.ErlSysMon do
  @moduledoc """
  Logs Erlang System Monitor events.
  """

  use GenServer

  require Logger

  @defults [
    :busy_dist_port,
    :busy_port,
    {:long_gc, 250},
    {:long_schedule, 100}
  ]
  def start_link(args \\ @defults), do: GenServer.start_link(__MODULE__, args)

  def init(args) do
    :erlang.system_monitor(self(), args)
    {:ok, []}
  end

  def handle_info(msg, state) do
    Logger.warning("#{__MODULE__} message: " <> inspect(msg))
    {:noreply, state}
  end
end
