defmodule RealtimeWeb.PageControllerTest do
  use RealtimeWeb.ConnCase

  test "GET / renders index page", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ " Supabase Realtime: Multiplayer Edition"
  end

  test "GET /healthcheck returns ok status", %{conn: conn} do
    conn = get(conn, "/healthcheck")
    assert text_response(conn, 200) == "ok"
  end
end
