defmodule RealtimeWeb.ApiKeyTest do
  use RealtimeWeb.ConnCase
  use RealtimeWeb.ChannelCase
  alias Realtime.Api

  test "no api key", %{conn: conn} do
    Application.put_env(:realtime, :api_key, nil)
    conn = get(conn, Routes.tenant_path(conn, :index))
    assert json_response(conn, 200)["data"] == []
  end

  test "api key doesn't pass", %{conn: conn} do
    Application.put_env(:realtime, :api_key, "big_secret")
    conn = get(conn, Routes.tenant_path(conn, :index))
    assert conn.status == 403
  end

  test "api key is right", %{conn: conn} do
    Application.put_env(:realtime, :api_key, "not_big_secret")

    conn =
      conn
      |> Plug.Conn.put_req_header("x-api-key", "not_big_secret")

    conn = get(conn, Routes.tenant_path(conn, :index))
    assert conn.status == 200
  end
end
