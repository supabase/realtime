defmodule RealtimeWeb.Plugs.AssignTenantTest do
  use RealtimeWeb.ConnCase

  alias Realtime.Api

  @tenant %{
    "external_id" => "localhost",
    "name" => "localhost",
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "postgres",
          "db_password" => "postgres",
          "db_port" => "6432",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1"
        }
      }
    ],
    "postgres_cdc_default" => "postgres_cdc_rls",
    "jwt_secret" => "new secret"
  }

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")

    {:ok, _tenant} = Api.create_tenant(@tenant)

    {:ok, conn: conn}
  end

  test "serve a 401 unauthorized when we can't find a tenant", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "not-found-tenant.localhost.com")
      |> get(Routes.ping_path(conn, :ping))

    assert conn.status == 401
  end

  @tag :failing
  test "serve a 401 unauthorized when we have a bad request", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "localhost.com")
      |> get(Routes.ping_path(conn, :ping))

    assert conn.status == 401
  end

  test "assigns a tenant", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "localhost.localhost.com")
      |> get(Routes.ping_path(conn, :ping))

    assert conn.status == 200
  end

  test "assigns a tenant even with lots of subdomains", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "localhost.realtime.localhost.com")
      |> get(Routes.ping_path(conn, :ping))

    assert conn.status == 200
  end
end
