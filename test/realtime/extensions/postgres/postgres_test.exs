defmodule Realtime.Extensions.PostgresTest do
  use RealtimeWeb.ChannelCase
  use RealtimeWeb.ConnCase

  import Mock
  import Extensions.Postgres.Helpers, only: [filter_postgres_settings: 1]

  alias Extensions.Postgres
  alias Realtime.Api
  alias RealtimeWeb.ChannelsAuthorization
  alias Postgrex, as: P

  @external_id "dev_tenant"
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ5OTYzNTc1LCJleHAiOjE5NjU1Mzk1NzV9.v7UZK05KaVQKInBBH_AP5h0jXUEwCCC5qtdj3iaxbNQ"

  setup %{} do
    {:ok, _pid} = start_supervised(RealtimeWeb.Joken.CurrentTime.Mock)
    tenant = Api.get_tenant_by_external_id(@external_id)

    assigns = %{
      token: @token,
      jwt_secret: tenant.jwt_secret,
      tenant: tenant.external_id,
      postgres_extension: filter_postgres_settings(tenant.extensions),
      claims: %{},
      limits: %{
        max_concurrent_users: 1
      },
      is_new_api: false
    }

    with_mocks([
      {ChannelsAuthorization, [],
       [
         authorize_conn: fn _, _ ->
           {:ok, %{"exp" => Joken.current_time() + 1_000, "role" => "postgres"}}
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
    test "Check supervisor crash and respawn" do
      sup =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          {:tenant_db, :supervisor, @external_id}
          |> :global.whereis_name()
          |> case do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            pid ->
              {:halt, pid}
          end
        end)

      assert Process.alive?(sup)
      DynamicSupervisor.terminate_child(Postgres.DynamicSupervisor, sup)
      Process.sleep(5_000)
      sup2 = :global.whereis_name({:tenant_db, :supervisor, @external_id})
      assert Process.alive?(sup2)
      assert(sup != sup2)
    end

    test "Subscription manager updates oids" do
      subscriber_manager_pid =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          {:tenant_db, :replication, :poller, @external_id}
          |> :global.whereis_name()
          |> case do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            _ ->
              {:halt, Postgres.manager_pid(@external_id)}
          end
        end)

      %{conn: conn, oids: oids} = :sys.get_state(subscriber_manager_pid)

      P.query!(conn, "drop publication supabase_realtime_test", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids2} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids, oids2)

      P.query!(conn, "create publication supabase_realtime_test for all tables", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids3} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids2, oids3)
    end

    test "Stop tenant supervisor" do
      [sup, manager, poller] =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          pids = [
            :global.whereis_name({:tenant_db, :supervisor, @external_id}),
            :global.whereis_name({:tenant_db, :replication, :manager, @external_id}),
            :global.whereis_name({:tenant_db, :replication, :poller, @external_id})
          ]

          pids
          |> Enum.all?(&is_pid(&1))
          |> case do
            true ->
              {:halt, pids}

            false ->
              Process.sleep(500)
              {:cont, acc}
          end
        end)

      assert Process.alive?(sup)
      assert Process.alive?(manager)
      assert Process.alive?(poller)

      Postgres.stop(@external_id)

      assert Process.alive?(sup) == false
      assert Process.alive?(manager) == false
      assert Process.alive?(poller) == false
    end
  end
end
