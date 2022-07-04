defmodule RealtimeWeb.MetricsControllerTest do
  use RealtimeWeb.ConnCase

  import Mock
  alias RealtimeWeb.{ChannelsAuthorization, JwtVerification}

  @valid_region "valid_region"
  @not_valid_region "not_valid_region"

  setup %{conn: conn} do
    :syn.join(Extensions.Postgres.RegionNodes, @valid_region, self(), node: node())
    Application.put_env(:realtime, :metrics_jwt_secret, "test")

    new_conn =
      conn
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    {:ok, conn: new_conn}
  end

  test "not found", %{conn: conn} do
    with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
      conn = get(conn, Routes.metrics_path(conn, :index, @not_valid_region, "0"))
      assert conn.status == 404
    end
  end

  test "node exist", %{conn: conn} do
    with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
      conn = get(conn, Routes.metrics_path(conn, :index, @valid_region, "0"))
      assert conn.status == 200
    end
  end
end
