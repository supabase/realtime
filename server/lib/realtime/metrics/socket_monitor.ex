# This file draws from https://github.com/pushex-project/pushex
# License: https://github.com/pushex-project/pushex/blob/master/LICENSE

defmodule Realtime.Metrics.SocketMonitor do
  use GenServer
  alias Realtime.Metrics.PromEx.Plugins.Realtime

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    {:ok, %{transport_pids: %{}, channel_pids: %{}}}
  end

  def track_socket(socket = %Phoenix.Socket{}) do
    GenServer.cast(__MODULE__, {:track_socket, socket})
  end

  def track_channel(socket = %Phoenix.Socket{}) do
    GenServer.cast(__MODULE__, {:track_channel, socket})
  end

  ## Callbacks

  def handle_cast(
        {:track_socket, %Phoenix.Socket{transport_pid: transport_pid}},
        state = %{transport_pids: transport_pids}
      ) do
    Process.monitor(transport_pid)

    new_transport_pids =
      Map.put(transport_pids, transport_pid, %{
        online_at: unix_ms_now()
      })

    execute_socket_telemetry(new_transport_pids)

    {:noreply, %{state | transport_pids: new_transport_pids}}
  end

  def handle_cast(
        {:track_channel, %Phoenix.Socket{channel_pid: channel_pid, topic: topic}},
        state = %{channel_pids: channel_pids}
      ) do
    Process.monitor(channel_pid)

    new_channel_pids =
      Map.put(channel_pids, channel_pid, %{
        channel: topic,
        online_at: unix_ms_now()
      })

    execute_channel_telemetry(new_channel_pids)

    {:noreply, %{state | channel_pids: new_channel_pids}}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        state = %{transport_pids: transport_pids, channel_pids: channel_pids}
      ) do
    new_transport_pids = Map.delete(transport_pids, pid)
    new_channel_pids = Map.delete(channel_pids, pid)

    execute_socket_telemetry(new_transport_pids)
    execute_channel_telemetry(new_channel_pids)

    {:noreply, %{state | transport_pids: new_transport_pids, channel_pids: new_channel_pids}}
  end

  defp execute_socket_telemetry(pids),
    do: :telemetry.execute(Realtime.socket_event(), %{active_socket_total: map_size(pids)})

  defp execute_channel_telemetry(pids),
    do: :telemetry.execute(Realtime.channel_event(), %{active_channel_total: map_size(pids)})

  defp unix_ms_now(), do: :erlang.system_time(:millisecond)
end
