defmodule RealtimeWeb.PageLive.Index do
  use RealtimeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_time(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  def handle_info(:time, socket) do
    {:noreply, assign_time(socket)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Notifications")
  end

  defp assign_time(socket) do
    Process.send_after(self(), :time, 100)
    now = DateTime.utc_now() |> DateTime.to_string()

    socket =
      socket
      |> assign(:server_time, now)
  end
end
