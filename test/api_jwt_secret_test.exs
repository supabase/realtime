defmodule RealtimeWeb.ApiJwtSecretTest do
  use RealtimeWeb.ConnCase
  import Mock
  alias RealtimeWeb.JwtVerification

  test "no api key", %{conn: conn} do
    Application.put_env(:realtime, :api_jwt_secret, nil)
    conn = get(conn, Routes.tenant_path(conn, :index))
    assert conn.status == 403
  end

  test "api key is right", %{conn: conn} do
    with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
      jwt = "jwt_token"

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> jwt)

      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 200
    end
  end
end
