defmodule RealtimeWeb.InspectorLive.IndexTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "Inspector LiveView" do
    test "renders inspector page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/inspector")

      assert html =~ "Realtime Inspector"
    end
  end
end
