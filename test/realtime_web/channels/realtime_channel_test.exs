defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  use RealtimeWeb.ConnCase

  import Mock

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias RealtimeWeb.{ChannelsAuthorization, JwtVerification}

  @create_attrs %{
    external_id: "some external_id",
    active: true,
    name: "some name",
    db_host: "db.awesome.supabase.net",
    db_name: "postgres",
    db_password: "postgres",
    db_port: "6543",
    region: "eu-central-1",
    db_user: "postgres",
    jwt_secret: "some jwt_secret",
    rls_poll_interval: 500
  }

  def fixture(:tenant) do
    {:ok, tenant} = Api.create_tenant(@create_attrs)
    tenant
  end

  setup %{conn: conn} do
    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    %{conn: new_conn}
  end

  describe "limit max_concurrent_users" do
    test "not reached", %{conn: conn} do
      assert {:ok, _, socket} =
               RealtimeWeb.UserSocket
               |> socket("user_id", %{assigns() | limits: %{max_concurrent_users: 1}})
               |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:topic")
    end

    test "reached", %{conn: conn} do
      assert {:error, %{reason: "reached max_concurrent_users limit"}} =
               RealtimeWeb.UserSocket
               |> socket("user_id", %{assigns() | limits: %{max_concurrent_users: -1}})
               |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:topic")
    end
  end

  defp assigns() do
    claims = %{}
    tenant = "localhost"
    assigns = %{tenant: tenant, claims: claims, limits: %{}}
  end

  defp create_tenant(_) do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end
end
