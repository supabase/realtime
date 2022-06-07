defmodule Realtime.Extensions.PostgresTest do
  use RealtimeWeb.ChannelCase
  use RealtimeWeb.ConnCase

  import Mock

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias RealtimeWeb.{ChannelsAuthorization, Joken.CurrentTime, UserSocket}
  import Extensions.Postgres.Helpers, only: [filter_postgres_settings: 1]
  alias Extensions.Postgres
  alias Postgrex, as: P

  @external_id "dev_tenant"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ5OTYzNTc1LCJleHAiOjE5NjU1Mzk1NzV9.v7UZK05KaVQKInBBH_AP5h0jXUEwCCC5qtdj3iaxbNQ"

  setup %{} do
    {:ok, _pid} = start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
    tenant = Api.get_dec_tenant_by_external_id(@external_id)

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

    with_mocks([
      {ChannelsAuthorization, [],
       [
         authorize_conn: fn _, _ ->
           {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "test_role"}}
         end
       ]}
    ]) do
      {:ok, _, socket} =
        RealtimeWeb.UserSocket
        |> socket("user_id", assigns)
        |> subscribe_and_join(RealtimeWeb.RealtimeChannel, "realtime:*", %{"user_token" => @token})

      %{socket: socket, tenant: tenant}
    end
  end

  describe "Postgres extensions" do
    test "Check supervisor crash and respawn", %{socket: _socket, tenant: %Tenant{} = _tenant} do
      sup = :global.whereis_name({:supervisor, @external_id})
      assert Process.alive?(sup)
      DynamicSupervisor.terminate_child(Postgres.DynamicSupervisor, sup)
      Process.sleep(500)
      sup2 = :global.whereis_name({:supervisor, @external_id})
      assert Process.alive?(sup2)
      assert(sup != sup2)
    end

    test "Subscription manager updates oids", %{} do
      subscriber_manager_pid = Postgres.manager_pid(@external_id)
      %{conn: conn, oids: oids} = :sys.get_state(subscriber_manager_pid)

      P.query(conn, "drop publication supabase_multiplayer", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids2} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids, oids2)

      P.query(conn, "create publication supabase_multiplayer for all tables", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids3} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids2, oids3)
    end
  end
end
