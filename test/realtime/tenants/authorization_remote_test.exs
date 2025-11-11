defmodule Realtime.Tenants.AuthorizationRemoteTest do
  # async: false due to usage of Clustered
  # Also using dev_tenant due to distributed test
  use RealtimeWeb.ConnCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  require Phoenix.ChannelTest

  alias Realtime.Database
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Connect

  setup [:rls_context]

  describe "get_authorizations" do
    @tag role: "authenticated",
         policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "authenticated user has expected policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: nil},
               presence: %PresencePolicies{read: true, write: nil}
             } == policies

      {:ok, policies} =
        Authorization.get_write_authorizations(
          policies,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: true, write: true}
             } == policies
    end

    @tag role: "anon",
         policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "anon user has no policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: nil},
               presence: %PresencePolicies{read: false, write: nil}
             } == policies

      {:ok, policies} =
        Authorization.get_write_authorizations(
          policies,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } == policies
    end

    @tag role: "anon",
         policies: []
    test "db process is down", context do
      # Grab a remote pid that will not exist in the near future. erpc uses a new process to perform the call.
      # Once it has returned the process is not alive anymore
      db_conn = :erpc.call(context.node, :erlang, :self, [])

      {:error, :increase_connection_pool} =
        Authorization.get_read_authorizations(%Policies{}, db_conn, context.authorization_context)

      {:error, :increase_connection_pool} =
        Authorization.get_write_authorizations(%Policies{}, db_conn, context.authorization_context)
    end

    @tag role: "anon", policies: []
    test "get_read_authorizations rate limit when db has many connection errors", context do
      pid = :erpc.call(context.node, :erlang, :self, [])

      log =
        capture_log(fn ->
          for _ <- 1..6 do
            {:error, :increase_connection_pool} =
              Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)
          end

          # Force RateCounter to tick
          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)

          for _ <- 1..10 do
            {:error, :increase_connection_pool} =
              Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)
          end
        end)

      assert log =~ "IncreaseConnectionPool: Too many database timeouts"

      # Only one log message should be emitted
      # Splitting by the error message returns the error message and the rest of the log only
      assert length(String.split(log, "IncreaseConnectionPool: Too many database timeouts")) == 2
    end

    @tag role: "anon", policies: []
    test "get_write_authorizations rate limit when db has many connection errors", context do
      pid = spawn(fn -> :ok end)

      log =
        capture_log(fn ->
          for _ <- 1..6 do
            {:error, :increase_connection_pool} =
              Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context)
          end

          # Force RateCounter to tick
          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)

          for _ <- 1..10 do
            {:error, :increase_connection_pool} =
              Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context)
          end
        end)

      assert log =~ "IncreaseConnectionPool: Too many database timeouts"

      # Only one log message should be emitted
      # Splitting by the error message returns the error message and the rest of the log only
      assert length(String.split(log, "IncreaseConnectionPool: Too many database timeouts")) == 2
    end
  end

  describe "database error" do
    @tag role: "authenticated",
         policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence],
         timeout: :timer.minutes(1)
    test "handles small pool size", context do
      task =
        Task.async(fn ->
          :erpc.call(node(context.db_conn), Postgrex, :query!, [
            context.db_conn,
            "SELECT pg_sleep(19)",
            [],
            [timeout: :timer.seconds(20)]
          ])
        end)

      Process.sleep(100)

      log =
        capture_log(fn ->
          t1 =
            Task.async(fn ->
              assert {:error, :increase_connection_pool} =
                       Authorization.get_read_authorizations(
                         %Policies{},
                         context.db_conn,
                         context.authorization_context
                       )
            end)

          t2 =
            Task.async(fn ->
              assert {:error, :increase_connection_pool} =
                       Authorization.get_write_authorizations(
                         %Policies{},
                         context.db_conn,
                         context.authorization_context
                       )
            end)

          Task.await_many([t1, t2], 20_000)
          # Force RateCounter to tick and log error
          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)
        end)

      external_id = context.tenant.external_id

      assert log =~
               "project=#{external_id} external_id=#{external_id} [critical] IncreaseConnectionPool: Too many database timeouts"

      Task.await(task, :timer.seconds(30))
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "broken RLS policy returns error", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context
               )
    end
  end

  defp rls_context(context) do
    tenant = Realtime.Tenants.get_tenant_by_external_id("dev_tenant")
    Connect.shutdown("dev_tenant")
    # Waiting for :syn to unregister
    Process.sleep(100)
    RateCounterHelper.stop("dev_tenant")

    {:ok, local_db_conn} = Database.connect(tenant, "realtime_test", :stop)
    topic = random_string()

    clean_table(local_db_conn, "realtime", "messages")

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    Realtime.Tenants.Migrations.create_partitions(local_db_conn)
    create_rls_policies(local_db_conn, context.policies, %{topic: topic})

    {:ok, node} = Clustered.start()
    region = Tenants.region(tenant)
    {:ok, db_conn} = :erpc.call(node, Connect, :connect, ["dev_tenant", region])

    assert node(db_conn) == node

    %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      node: node,
      authorization_context: authorization_context
    }
  end
end
