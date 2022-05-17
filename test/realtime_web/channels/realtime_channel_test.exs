defmodule RealtimeWeb.RealtimeChannelTest do
  use RealtimeWeb.ChannelCase
  use RealtimeWeb.ConnCase

  import Mock

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias RealtimeWeb.{ChannelsAuthorization, JwtVerification}
  import Extensions.Postgres.Helpers, only: [filter_postgres_settings: 1]
  import Postgrex, only: [query: 3]

  @external_id "external_id"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ5OTYzNTc1LCJleHAiOjE5NjU1Mzk1NzV9.Kf2Pfwaqkw_zNL73phdrQEgdRiNI_JRHBgmXVJ6M1sQ"

  @postgres_ext %{
    "db_host" => "127.0.0.1",
    "db_name" => "postgres",
    "db_user" => "postgres",
    "db_password" => "postgres",
    "publication" => "realtime_test",
    "db_port" => "6432",
    "poll_interval_ms" => 100,
    "poll_max_changes" => 100,
    "poll_max_record_bytes" => 1_048_576,
    "region" => "us-east-1"
  }

  @valid_attrs %{
    external_id: @external_id,
    name: "localhost",
    extensions: [
      %{
        "type" => "postgres",
        "settings" => @postgres_ext
      }
    ],
    jwt_secret: "new secret"
  }

  def fixture(:tenant) do
    {:ok, tenant} =
      @valid_attrs
      |> Api.create_tenant()

    @external_id
    |> Realtime.Api.get_dec_tenant_by_external_id()
  end

  setup %{conn: conn} do
    Application.put_env(:realtime, :db_enc_key, "1234567890123456")
    tenant = fixture(:tenant)

    assigns =
      assigns = %{
        token: @token,
        jwt_secret: tenant.jwt_secret,
        tenant: tenant.external_id,
        postgres_extension: filter_postgres_settings(tenant.extensions),
        claims: %{},
        limits: %{
          max_concurrent_users: 1
        }
      }

    {:ok, _, socket} =
      RealtimeWeb.UserSocket
      |> socket("user_id", assigns)
      |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*")

    %{socket: socket, tenant: tenant}
  end

  # describe "limit max_concurrent_users" do
  #   test "not reached", %{conn: conn} do
  #     assert {:ok, _, socket} =
  #              RealtimeWeb.UserSocket
  #              |> socket("user_id", %{assigns() | limits: %{max_concurrent_users: 1}})
  #              |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:topic")
  #   end

  #   test "reached", %{conn: conn} do
  #     assert {:error, %{reason: "reached max_concurrent_users limit"}} =
  #              RealtimeWeb.UserSocket
  #              |> socket("user_id", %{assigns() | limits: %{max_concurrent_users: -1}})
  #              |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:topic")
  #   end
  # end

  describe "Postgres extensions" do
    test "Check supervisor crash and respawn", %{socket: socket, tenant: %Tenant{} = tenant} do
      sup = :global.whereis_name({:supervisor, @external_id})
      assert Process.alive?(sup)
      DynamicSupervisor.terminate_child(Extensions.Postgres.DynamicSupervisor, sup)
      :timer.sleep(500)
      sup2 = :global.whereis_name({:supervisor, @external_id})
      assert Process.alive?(sup2)
      assert(sup != sup2)
    end
  end

  defp assigns() do
    claims = %{}
    tenant = "localhost"

    assigns = %{
      tenant: tenant,
      claims: claims,
      limits: %{},
      tenant_extensions: [],
      postgres_extension: @postgres_ext
    }
  end

  defp create_tenant(_) do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end
end
