defmodule Realtime.ErlSysMon do
  @moduledoc """
  Logs Erlang System Monitor events.
  """

  use GenServer

  require Logger

  @defaults [
    :busy_dist_port,
    :busy_port,
    {:long_gc, 250},
    {:long_schedule, 100},
    {:long_message_queue, {0, 1_000}}
  ]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def init(args) do
    config = Keyword.get(args, :config, @defaults)
    :erlang.system_monitor(self(), config)

    {:ok, []}
  end

  def handle_info(msg, state) do
    Logger.error("#{__MODULE__} message: " <> inspect(msg))
    {:noreply, state}
  end
end
