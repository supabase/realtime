defmodule RealtimeWeb.PageLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "Index LiveView" do
    test "renders page successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Supabase Realtime: Multiplayer Edition"
    end
  end
end
