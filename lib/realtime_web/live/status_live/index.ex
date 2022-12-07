defmodule RealtimeWeb.StatusLive.Index do
  use RealtimeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: RealtimeWeb.Endpoint.subscribe("admin:cluster")
    {:ok, assign(socket, pings: default_pings(), nodes: Enum.count(all_nodes()))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{payload: payload}, socket) do
    payload = %{
      payload.from_node => %{
        node: payload.node,
        latency: payload.latency,
        response: payload.response
      }
    }

    pings = Map.merge(socket.assigns.pings, payload)

    {:noreply, assign(socket, pings: pings)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Status - Supabase Realtime")
  end

  defp all_nodes() do
    [Node.self() | Node.list()]
  end

  defp default_pings() do
    for n <- all_nodes(), f <- all_nodes(), into: %{} do
      {n, %{from_node: f, latency: 0, node: "Loading..."}}
    end
  end
end
