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

  defp assign_time(socket) do
    timer = if Mix.env() == :dev, do: 60_000, else: 100
    Process.send_after(self(), :time, timer)
    now = DateTime.utc_now() |> DateTime.to_string()

    socket
    |> assign(:server_time, now)
  end
end
