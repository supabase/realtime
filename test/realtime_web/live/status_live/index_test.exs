defmodule RealtimeWeb.StatusLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Realtime.Latency.Payload
  alias Realtime.Nodes
  alias RealtimeWeb.Endpoint

  describe "Status LiveView" do
    test "renders status page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/status")

      assert html =~ "Realtime Status"
    end

    test "receives broadcast from PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/status")

      payload = %Payload{
        from_node: Nodes.short_node_id_from_name(:"pink@127.0.0.1"),
        node: Nodes.short_node_id_from_name(:"orange@127.0.0.1"),
        latency: "42ms",
        timestamp: DateTime.utc_now()
      }

      Endpoint.broadcast("admin:cluster", "ping", payload)

      html = render(view)
      assert html =~ "42ms"
      assert html =~ "pink@127.0.0.1_orange@127.0.0.1"
    end
  end
end
