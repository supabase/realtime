defmodule Realtime.Tenants.AuthorizationTest do
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  require Phoenix.ChannelTest

  import ExUnit.CaptureLog

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Tenants.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  setup [:rls_context]

  describe "get_authorizations/3" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context)

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: true, write: true}
             } == policies
    end

    @tag role: "authenticated",
         policies: [:authenticated_read_matching_user_sub],
         sub: "ccbdfd51-c5aa-4d61-8c17-647664466a26"
    test "authenticated user sub is available", context do
      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: true, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      authorization_context = %{context.authorization_context | sub: "135f6d25-5840-4266-a8ca-b9a45960e424"}

      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: false, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, authorization_context)
    end

    @tag role: "authenticated",
         policies: [:read_matching_user_role]
    test "user role is exposed", context do
      # policy role is checking for "authenticated"
      # set_config is setting request.jwt.claim.role to authenticated as well
      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: true, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      authorization_context = %{context.authorization_context | role: "anon"}

      # policy role is checking for "authenticated"
      # set_config is setting request.jwt.claim.role to anon
      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: false, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, authorization_context)
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context)

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } == policies
    end

    @tag role: "anon", policies: []
    test "db process is down", context do
      pid = spawn(fn -> :ok end)

      {:error, :increase_connection_pool} =
        Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)

      {:error, :increase_connection_pool} =
        Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context)
    end

    @tag role: "anon", policies: []
    test "get_read_authorizations rate limit when db has many connection errors", context do
      update_db_pool_size(context.tenant, 5)
      pid = spawn(fn -> :ok end)

      log =
        capture_log(fn ->
          for _ <- 1..6 do
            {:error, :increase_connection_pool} =
              Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)
          end

          # Force RateCounter to tick
          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)
          # The next auth requests will not call the database due to being rate limited
          reject(&Database.transaction/4)

          for _ <- 1..10 do
            {:error, :increase_connection_pool} =
              Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)
          end
        end)

      assert log =~ "IncreaseConnectionPool: Too many database timeouts"

      # Only one or two log messages should be emitted
      assert length(String.split(log, "IncreaseConnectionPool: Too many database timeouts")) <= 3
    end

    @tag role: "anon", policies: []
    test "get_write_authorizations rate limit when db has many connection errors", context do
      update_db_pool_size(context.tenant, 5)
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
          # The next auth requests will not call the database due to being rate limited
          reject(&Database.transaction/4)

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
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ],
         timeout: :timer.minutes(1)
    test "handles small pool size", context do
      task =
        Task.async(fn ->
          Postgrex.query!(context.db_conn, "SELECT pg_sleep(19)", [], timeout: :timer.seconds(20))
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
      assert log =~ "project=#{external_id} external_id=#{external_id} [error] ErrorExecutingTransaction"

      assert log =~
               "project=#{external_id} external_id=#{external_id} [critical] IncreaseConnectionPool: Too many database timeouts"

      Task.await(task, :timer.seconds(30))
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "broken RLS policy sets policies to false and shows error to user", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end
  end

  describe "ensure database stays clean" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, _} = Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
      {:ok, _} = Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      assert {:ok, []} = Repo.all(db_conn, Message, Message)
    end
  end

  describe "telemetry" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]

    test "sends telemetry event", context do
      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      events = [
        [:realtime, :tenants, :write_authorization_check],
        [:realtime, :tenants, :read_authorization_check]
      ]

      :telemetry.attach_many(
        __MODULE__,
        events,
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      {:ok, _} = Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
      {:ok, _} = Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      external_id = context.authorization_context.tenant_id

      assert_receive {:telemetry_event, [:realtime, :tenants, :read_authorization_check], %{latency: _},
                      %{tenant: ^external_id}}

      assert_receive {:telemetry_event, [:realtime, :tenants, :write_authorization_check], %{latency: _},
                      %{tenant: ^external_id}}
    end
  end

  def rls_context(context) do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    topic = context[:topic] || random_string()

    create_rls_policies(db_conn, context.policies, %{topic: topic, sub: context[:sub], role: context.role})

    claims = %{"sub" => context[:sub] || random_string(), "role" => context.role, "exp" => Joken.current_time() + 1_000}

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims["role"],
        sub: claims["sub"]
      })

    Realtime.Tenants.Migrations.create_partitions(db_conn)

    on_exit(fn -> Process.exit(db_conn, :kill) end)

    %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end

  defp update_db_pool_size(tenant, db_pool) do
    extension = hd(tenant.extensions)

    settings = Map.put(extension.settings, "db_pool", db_pool)

    extensions = [Map.from_struct(%{extension | :settings => settings})]

    {:ok, tenant} = Realtime.Api.update_tenant(tenant, %{extensions: extensions})

    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})
  end
end
