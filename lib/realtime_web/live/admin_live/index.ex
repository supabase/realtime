defmodule RealtimeWeb.AdminLive.Index do
  use RealtimeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.utc_now() |> DateTime.to_string()

    socket =
      socket
      |> assign(:server_time, now)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Admin - Supabase Realtime")
  end
end
