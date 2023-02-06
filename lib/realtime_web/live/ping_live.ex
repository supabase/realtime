defmodule RealtimeWeb.PingLive do
  use RealtimeWeb, :live_view

  def mount(_params, _session, socket) do
    ping()
    {:ok, assign(socket, :ping, "0.0 ms")}
  end

  def render(assigns) do
    ~H"""
    <span class="font-mono" id="latency" phx-hook="latency"><%= @ping %></span>
    """
  end

  def handle_info(:ping, socket) do
    socket = socket |> push_event("ping", %{ping: DateTime.utc_now() |> DateTime.to_iso8601()})

    {:noreply, socket}
  end

  def handle_event("pong", %{"ping" => ping}, socket) do
    {:ok, datetime, 0} = DateTime.from_iso8601(ping)

    pong =
      (DateTime.diff(DateTime.utc_now(), datetime, :microsecond) / 1000)
      |> Float.round(1)
      |> Float.to_string()

    ping()
    {:noreply, assign(socket, :ping, pong <> " ms")}
  end

  defp ping() do
    timer = if Mix.env() == :dev, do: 60_000, else: 1_000
    Process.send_after(self(), :ping, timer)
  end
end
