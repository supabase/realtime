defmodule RealtimeWeb.MetricsControllerTest do
  use RealtimeWeb.ConnCase

  import Mock
  alias RealtimeWeb.JwtVerification

  setup %{conn: conn} do
    new_conn =
      conn
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    {:ok, conn: new_conn}
  end

  test "exporting metrics", %{conn: conn} do
    with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
      conn = get(conn, Routes.metrics_path(conn, :index))
      assert conn.status == 200
      lines = String.split(conn.resp_body, "\n") |> length()
      assert lines > 0
    end
  end
end
