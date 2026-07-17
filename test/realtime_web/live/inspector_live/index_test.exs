defmodule RealtimeWeb.InspectorLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "Inspector LiveView" do
    test "renders inspector page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Realtime Control Center"
    end

    test "transport_status ok renders the round-trip latency", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "transport_status", %{"status" => "ok", "latency_ms" => 42.0})

      assert html =~ "42.0"
    end

    test "channel_status joined shows the connected host, errored/timed_out render distinctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "channel_status", %{"status" => "joined", "host" => "example.supabase.co"})
      assert html =~ "Connected to example.supabase.co"

      html = render_hook(view, "channel_status", %{"status" => "errored", "reason" => "RLS denied"})
      assert html =~ "Error: RLS denied"
      refute html =~ "Connected to example.supabase.co"

      html = render_hook(view, "channel_status", %{"status" => "timed_out"})
      assert html =~ "Timed out"
    end

    test "disconnect resets every health layer back to idle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      render_hook(view, "transport_status", %{"status" => "ok", "latency_ms" => 12.0})
      render_hook(view, "channel_status", %{"status" => "joined", "host" => "example.supabase.co"})
      render_hook(view, "presence_synced", %{"count" => 2})
      html = render_hook(view, "postgres_subscribed", %{"schema" => "public", "table" => "messages", "filter" => ""})

      assert html =~ "Connected to example.supabase.co"
      assert html =~ "Synced (2)"
      assert html =~ "Subscribed: public.messages"

      html = render_hook(view, "channel_status", %{"status" => "closed"})

      assert html =~ "Not connected"
      assert html =~ "Not subscribed"
      refute html =~ "Synced (2)"
      refute html =~ "Subscribed: public.messages"

      # transport disconnect also resets, independent of channel_status
      render_hook(view, "channel_status", %{"status" => "joined", "host" => "example.supabase.co"})
      html = render_hook(view, "transport_status", %{"status" => "disconnected", "latency_ms" => nil})

      assert html =~ "Not connected"
    end

    test "presence_synced fires independent of any peer joining", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "presence_synced", %{"count" => 0})

      assert html =~ "Synced (0)"
    end

    test "postgres_error renders the error reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = render_hook(view, "postgres_error", %{"reason" => "table not in publication"})

      assert html =~ "Error: table not in publication"
    end

    test "invalid JSON payload renders an error instead of sending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#message_form", message: %{event: "test", payload: "not json"})
        |> render_submit()

      assert html =~ "invalid JSON"
    end

    test "valid JSON payload is decoded before being pushed to the client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#message_form", message: %{event: "greet", payload: ~s({"hello":"world"})})
      |> render_submit()

      assert_push_event(view, "send_message", %{"message" => %{"event" => "greet", "payload" => %{"hello" => "world"}}})
    end
  end
end
