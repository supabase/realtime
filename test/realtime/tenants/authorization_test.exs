defmodule Realtime.Tenants.AuthorizationTest do
  # Every check runs against both implementations: the realtime.authorize function and the
  # transaction it replaces.
  use RealtimeWeb.ConnCase,
    async: true,
    parameterize: [%{authorize_function: false}, %{authorize_function: true}]

  use Mimic

  setup :set_mimic_from_context

  import ExUnit.CaptureLog

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.FeatureFlags
  alias Realtime.Tenants.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  setup [:checkout_tenant_and_connect, :rls_context, :use_authorize_function]

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
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :broadcast)

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :presence)

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
      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: true, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      authorization_context = %{context.authorization_context | role: "anon"}

      assert {:ok, %Policies{broadcast: %BroadcastPolicies{read: false, write: nil}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, authorization_context)
    end

    @tag role: "authenticated",
         policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
    test "checks only the requested broadcast write policy", context do
      {:ok, policies} =
        Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context,
          presence_enabled?: false
        )

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :broadcast)

      # Presence is left unevaluated since it was not checked.
      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: nil, write: nil}
             } == policies
    end

    @tag role: "authenticated", policies: [:authenticated_write_presence]
    test "checks only the requested presence write policy", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context, :presence)

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: nil},
               presence: %PresencePolicies{read: nil, write: true}
             } == policies
    end

    @tag role: "authenticated", policies: [:authenticated_write_broadcast, :authenticated_write_persistence]
    test "checks only the requested persistence write policy", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context,
          :persistence
        )

      # The persistence policy lands on broadcast.persist, leaving broadcast.write unevaluated.
      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: nil, persist: true},
               presence: %PresencePolicies{read: nil, write: nil}
             } == policies
    end

    @tag role: "authenticated", policies: [:authenticated_write_broadcast]
    test "denies persistence when only the broadcast write policy exists", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context, :broadcast)

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :persistence)

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: true, persist: false},
               presence: %PresencePolicies{read: nil, write: nil}
             } == policies
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
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :broadcast)

      {:ok, policies} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :presence)

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
        Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context, :broadcast)
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

          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)
          reject(&Database.transaction/4)
          reject(&Database.query/5)

          for _ <- 1..10 do
            {:error, :increase_connection_pool} =
              Authorization.get_read_authorizations(%Policies{}, pid, context.authorization_context)
          end
        end)

      assert log =~ "IncreaseConnectionPool: Too many database timeouts"

      own_line =
        "external_id=#{context.tenant.external_id} [critical] IncreaseConnectionPool: Too many database timeouts"

      assert length(String.split(log, own_line)) <= 3
    end

    @tag role: "anon", policies: []
    test "get_write_authorizations rate limit when db has many connection errors", context do
      update_db_pool_size(context.tenant, 5)
      pid = spawn(fn -> :ok end)

      log =
        capture_log(fn ->
          for _ <- 1..6 do
            {:error, :increase_connection_pool} =
              Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context, :broadcast)
          end

          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)
          reject(&Database.transaction/4)
          reject(&Database.query/5)

          for _ <- 1..10 do
            {:error, :increase_connection_pool} =
              Authorization.get_write_authorizations(%Policies{}, pid, context.authorization_context, :broadcast)
          end
        end)

      assert log =~ "IncreaseConnectionPool: Too many database timeouts"

      own_line =
        "external_id=#{context.tenant.external_id} [critical] IncreaseConnectionPool: Too many database timeouts"

      assert length(String.split(log, own_line)) == 2
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
      db_conn = saturable_conn(context.tenant)
      TestHelpers.hold_connections!(db_conn)

      log =
        capture_log(fn ->
          t1 =
            Task.async(fn ->
              assert {:error, :increase_connection_pool} =
                       Authorization.get_read_authorizations(
                         %Policies{},
                         db_conn,
                         context.authorization_context
                       )
            end)

          t2 =
            Task.async(fn ->
              assert {:error, :increase_connection_pool} =
                       Authorization.get_write_authorizations(
                         %Policies{},
                         db_conn,
                         context.authorization_context,
                         :broadcast
                       )
            end)

          Task.await_many([t1, t2], 20_000)
          rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(context.tenant)
          RateCounterHelper.tick!(rate_counter)
        end)

      external_id = context.tenant.external_id

      # A transaction logs the checkout failure; a single query returns it as an error.
      unless context.authorize_function do
        assert log =~ "project=#{external_id} external_id=#{external_id} [error] ErrorExecutingTransaction"
      end

      assert log =~
               "project=#{external_id} external_id=#{external_id} [critical] IncreaseConnectionPool: Too many database timeouts"
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "broken RLS policy sets policies to false and shows error to user", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :presence
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :presence
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :presence
               )
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

      {:ok, policies} =
        Authorization.get_write_authorizations(%Policies{}, context.db_conn, context.authorization_context, :broadcast)

      {:ok, _} =
        Authorization.get_write_authorizations(policies, context.db_conn, context.authorization_context, :presence)

      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      assert {:ok, []} = Repo.all(db_conn, Message, Message)
    end
  end

  describe "database error classification" do
    # Setting a role that does not exist fails with invalid_parameter_value
    @tag role: "super_admin", policies: []
    test "invalid_parameter_value Postgrex error is classified as rls_policy_error", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{postgres: %{code: :invalid_parameter_value}}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{postgres: %{code: :invalid_parameter_value}}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence,
           :slow_read,
           :slow_write
         ]
    test "query_canceled is classified as query_canceled", context do
      # A single-connection pool, so the timeout applies to the connection the checks run on.
      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      Postgrex.query!(db_conn, "SET statement_timeout = '100ms'", [])

      assert {:error, :query_canceled, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, db_conn, context.authorization_context)

      assert {:error, :query_canceled, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag role: "authenticated",
         policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "check_violation on messages is classified as missing_partition", context do
      %{rows: partitions} =
        Postgrex.query!(
          context.db_conn,
          "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
          []
        )

      for [partition] <- partitions, do: Postgrex.query!(context.db_conn, "DROP TABLE #{partition}", [])

      assert {:error, :missing_partition} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :missing_partition} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag role: "anon", policies: []
    test "DBConnection.ConnectionError is classified as tenant_database_unavailable", context do
      stub_database_error(
        {:error, %DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :error}}
      )

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag role: "anon", policies: []
    test "ssl recv: closed ConnectionError from Repo on read is classified as tenant_database_unavailable", context do
      conn_error = %DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :closed}
      stub(Repo, :insert_all_entries, fn _, _, _, _ -> {:error, conn_error} end)
      stub(Database, :query, fn _, _, _, _, _ -> {:error, conn_error} end)

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    @tag role: "anon", policies: []
    test "ssl recv: closed ConnectionError from Repo on write is classified as tenant_database_unavailable", context do
      conn_error = %DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :closed}
      stub(Repo, :insert, fn _, _, _, _ -> {:error, conn_error} end)
      stub(Database, :query, fn _, _, _, _, _ -> {:error, conn_error} end)

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag role: "anon", policies: []
    test "ssl recv: closed ConnectionError from Repo.all on read is classified as tenant_database_unavailable",
         context do
      conn_error = %DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :closed}
      stub(Repo, :all, fn _, _, _ -> {:error, conn_error} end)
      stub(Database, :query, fn _, _, _, _, _ -> {:error, conn_error} end)

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end
  end

  describe "telemetry" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]

    test "sends telemetry event", context do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:realtime, :tenants, :write_authorization_check],
          [:realtime, :tenants, :read_authorization_check]
        ])

      {:ok, _} = Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      {:ok, _} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context,
          :broadcast
        )

      external_id = context.authorization_context.tenant_id

      assert_receive {[:realtime, :tenants, :read_authorization_check], ^ref, %{latency: _}, %{tenant: ^external_id}}

      assert_receive {[:realtime, :tenants, :write_authorization_check], ^ref, %{latency: _}, %{tenant: ^external_id}}
    end
  end

  defp use_authorize_function(%{authorize_function: enabled?}) do
    stub(FeatureFlags, :enabled?, fn
      "use_authorize_function", _tenant_id -> enabled?
      name, tenant_id -> call_original(FeatureFlags, :enabled?, [name, tenant_id])
    end)

    :ok
  end

  defp stub_database_error(error) do
    stub(Database, :transaction, fn _, _, _, _ -> error end)
    stub(Database, :query, fn _, _, _, _, _ -> error end)
  end

  defp update_db_pool_size(tenant, db_pool) do
    extension = hd(tenant.extensions)

    settings = Map.put(extension.settings, "db_pool", db_pool)

    extensions = [Map.from_struct(%{extension | :settings => settings})]

    {:ok, tenant} = Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{extensions: extensions})

    Realtime.Tenants.Cache.update_cache(tenant)
  end

  # A one-connection pool that sheds a queued checkout in a few hundred milliseconds so tests
  # can assert how Authorization reports a `:queue_timeout` error.
  defp saturable_conn(tenant) do
    {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)
    # Linked to the test process, so it comes down with the test; no explicit teardown needed.
    {:ok, db_conn} = Database.connect_db(settings, queue_target: 50, queue_interval: 100)
    db_conn
  end
end
