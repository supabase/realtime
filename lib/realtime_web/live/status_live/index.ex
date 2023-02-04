defmodule RealtimeWeb.StatusLive.Index do
  use RealtimeWeb, :live_view

  alias Realtime.Latency.Payload
  alias Realtime.Helpers

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
  def handle_info(%Phoenix.Socket.Broadcast{payload: %Payload{} = payload}, socket) do
    pair = payload.from_node <> "_" <> payload.node
    payload = %{pair => payload}

    pings = Map.merge(socket.assigns.pings, payload)

    {:noreply, assign(socket, pings: pings)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Status - Supabase Realtime")
  end

  defp all_nodes() do
    [Node.self() | Node.list()] |> Enum.map(&Helpers.short_node_id_from_name/1)
  end

  defp default_pings() do
    for n <- all_nodes(), f <- all_nodes(), into: %{} do
      pair = n <> "_" <> f
      {pair, %Payload{from_node: f, latency: "Loading...", node: n, timestamp: "Loading..."}}
    end
  end
end
