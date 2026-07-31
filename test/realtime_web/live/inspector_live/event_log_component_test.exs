defmodule RealtimeWeb.InspectorLive.EventLogComponentTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  alias RealtimeWeb.InspectorLive.EventLogComponent

  setup %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    %{log: with_target(view, "#event_log")}
  end

  describe "EventLogComponent" do
    test "caps the stream at 500 entries, dropping the oldest", %{log: log} do
      for n <- 1..501 do
        render_hook(log, "log_event", %{"category" => "broadcast", "event" => "evt-#{n}", "payload" => %{}})
      end

      html = render(log)

      assert html =~ ~s(data-event="evt-501")
      refute html =~ ~s(data-event="evt-1")
    end

    test "pause buffers events behind a pending count, resume flushes them in order", %{log: log} do
      render_hook(log, "pause", %{})

      render_hook(log, "log_event", %{"category" => "broadcast", "event" => "buffered-1", "payload" => %{}})
      html = render_hook(log, "log_event", %{"category" => "broadcast", "event" => "buffered-2", "payload" => %{}})

      refute html =~ "buffered-1"
      refute html =~ "buffered-2"
      assert html =~ "2 new"

      html = render_hook(log, "resume", %{})

      assert html =~ ~s(data-event="buffered-1")
      assert html =~ ~s(data-event="buffered-2")
      refute html =~ ~r/\d+ new/
    end

    test "clear empties the log and resets the empty-state message", %{log: log} do
      render_hook(log, "log_event", %{"category" => "broadcast", "event" => "will-be-cleared", "payload" => %{}})
      html = render_hook(log, "clear", %{})

      refute html =~ "will-be-cleared"
      assert html =~ "No events yet"
    end

    test "toggle_category flips the button's active styling", %{log: log} do
      html = render(log)
      assert html =~ ~s(phx-value-category="broadcast")

      html = render_hook(log, "toggle_category", %{"category" => "broadcast"})
      # An inactive category button drops the brand-tinted active classes.
      refute html =~ ~r/phx-value-category="broadcast"[^>]*bg-brand-100/
    end
  end

  describe "hidden?/3" do
    test "hides entries from deactivated categories" do
      entry = %{category: :presence, event: "join", payload: %{}}
      active = MapSet.new([:broadcast, :postgres])

      assert EventLogComponent.hidden?(entry, active, "")
      refute EventLogComponent.hidden?(entry, MapSet.new([:presence]), "")
    end

    test "hides entries that don't match the search term" do
      entry = %{category: :broadcast, event: "cursor-move", payload: %{"x" => 1}}
      active = MapSet.new([:broadcast])

      refute EventLogComponent.hidden?(entry, active, "cursor")
      refute EventLogComponent.hidden?(entry, active, "")
      assert EventLogComponent.hidden?(entry, active, "nomatch")
    end

    test "search matches against payload contents too" do
      entry = %{category: :postgres, event: "INSERT", payload: %{"table" => "messages"}}
      active = MapSet.new([:postgres])

      refute EventLogComponent.hidden?(entry, active, "messages")
    end
  end
end
