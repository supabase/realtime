defmodule Realtime.Extensions.PostgresTest do
  use RealtimeWeb.ChannelCase
  use RealtimeWeb.ConnCase

  import Mock
  import Extensions.Postgres.Helpers, only: [filter_postgres_settings: 1]

  alias Extensions.Postgres
  alias Postgres.SubscriptionManager
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
        max_concurrent_users: 1,
        max_events_per_second: 1
      },
      is_new_api: false,
      log_level: :info
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
        Enum.reduce_while(1..15, nil, fn _, acc ->
          :syn.lookup(Extensions.Postgres.Sup, @external_id)
          |> case do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            {pid, _} ->
              {:halt, pid}
          end
        end)

      assert Process.alive?(sup)
      DynamicSupervisor.terminate_child(Postgres.DynamicSupervisor, sup)
      Process.sleep(5_000)
      {sup2, _} = :syn.lookup(Extensions.Postgres.Sup, @external_id)
      assert Process.alive?(sup2)
      assert(sup != sup2)
    end

    test "Subscription manager updates oids" do
      {subscriber_manager_pid, conn} =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          case Postgres.get_manager_conn(@external_id) do
            nil ->
              Process.sleep(500)
              {:cont, acc}

            {:ok, pid, conn} ->
              {:halt, {pid, conn}}
          end
        end)

      %SubscriptionManager.State{oids: oids} = :sys.get_state(subscriber_manager_pid)

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
      sup =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          :syn.lookup(Extensions.Postgres.Sup, @external_id)
          |> case do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            {pid, _} ->
              {:halt, pid}
          end
        end)

      assert Process.alive?(sup)
      Postgres.stop(@external_id)
      assert Process.alive?(sup) == false
    end
  end
end
