defmodule RealtimeWeb.TimeLive do
  use RealtimeWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign_time(socket)}
  end

  def render(assigns) do
    ~H"""
    <span class="font-mono"><%= @server_time %></span>
    """
  end

  def handle_info(:time, socket) do
    {:noreply, assign_time(socket)}
  end

  @time_timer if Application.compile_env(:realtime, :dev_mode, false), do: 60_000, else: 100

  defp assign_time(socket) do
    timer = @time_timer
    Process.send_after(self(), :time, timer)
    now = DateTime.utc_now() |> DateTime.to_string()

    socket
    |> assign(:server_time, now)
  end
end
