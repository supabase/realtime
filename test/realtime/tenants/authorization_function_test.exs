defmodule Realtime.Tenants.AuthorizationFunctionTest do
  # How Authorization picks between the realtime.authorize function and the transaction it
  # replaces. The policies each one reports are covered by AuthorizationTest, which runs against both.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  import ExUnit.CaptureLog

  alias Realtime.Database
  alias Realtime.FeatureFlags
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  @moduletag role: "authenticated",
             policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]

  @all_allowed %Policies{
    broadcast: %BroadcastPolicies{read: true, write: true},
    presence: %PresencePolicies{read: true, write: true}
  }

  setup [:checkout_tenant_and_connect, :rls_context]

  describe "feature flag" do
    test "checks policies in a transaction when the flag is off", context do
      use_authorize_function(false, 3)
      reject(&Database.query/5)

      assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context)
    end

    test "checks each policy in a single query when the flag is on", context do
      use_authorize_function(true, 3)
      reject(&Database.transaction/4)

      expect(Database, :query, 3, fn conn, statement, params, opts, metadata ->
        call_original(Database, :query, [conn, statement, params, opts, metadata])
      end)

      assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context)
    end

    test "role and request settings do not leak onto the connection", context do
      use_authorize_function(true, 3)
      # A single-connection pool, so the follow-up query runs on the connection the checks used.
      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")

      assert {:ok, @all_allowed} = check_all(db_conn, context.authorization_context)

      %{rows: [[session_user, current_user, topic, claims, sub, headers]]} =
        Postgrex.query!(
          db_conn,
          """
          SELECT session_user, current_user,
                 current_setting('realtime.topic', true),
                 current_setting('request.jwt.claims', true),
                 current_setting('request.jwt.claim.sub', true),
                 current_setting('request.headers', true)
          """,
          []
        )

      assert current_user == session_user
      assert topic in [nil, ""]
      assert claims in [nil, ""]
      assert sub in [nil, ""]
      assert headers in [nil, ""]
    end
  end

  describe "realtime.authorize" do
    # The probe inserts give the transaction an xid even though they are rolled back, so without
    # this every check would wait on a WAL flush and on sync standbys before returning.
    test "commits without waiting on the WAL flush", context do
      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      %{rows: [[default]]} = Postgrex.query!(db_conn, "SELECT current_setting('synchronous_commit')", [])

      {:ok, setting} =
        Postgrex.transaction(db_conn, fn conn ->
          Postgrex.query!(
            conn,
            """
            SELECT realtime.authorize('authenticated', 'topic', '{}', 'sub', '{}', '{broadcast}', '{broadcast}')
            """,
            []
          )

          %{rows: [[setting]]} = Postgrex.query!(conn, "SELECT current_setting('synchronous_commit')", [])
          setting
        end)

      assert setting == "off"

      # Only for the transaction that ran the check
      assert %{rows: [[^default]]} = Postgrex.query!(db_conn, "SELECT current_setting('synchronous_commit')", [])
    end
  end

  describe "fallback to a transaction" do
    test "when realtime.authorize does not exist yet", context do
      use_authorize_function(true, 3)

      # Connect hands out the connection before the tenant migrations finish.
      Postgrex.query!(context.db_conn, "DROP FUNCTION realtime.authorize", [])

      log =
        capture_log(fn -> assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context) end)

      assert log =~ "AuthorizeFunctionFallback"
    end

    test "when realtime.authorize returns an unexpected result", context do
      use_authorize_function(true, 3)

      # A result per extension is expected, but none come back.
      Postgrex.query!(
        context.db_conn,
        """
        CREATE OR REPLACE FUNCTION realtime.authorize(
          role_name text, topic_name text, claims text, sub text, headers text,
          read_extensions text[], write_extensions text[],
          OUT read_allowed boolean[], OUT write_allowed boolean[]
        )
        RETURNS record LANGUAGE sql AS $$ SELECT '{}'::boolean[], '{}'::boolean[] $$
        """,
        []
      )

      log =
        capture_log(fn -> assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context) end)

      assert log =~ "AuthorizeFunctionFallback"
    end
  end

  describe "no fallback" do
    setup do
      reject(&Database.transaction/4)
      :ok
    end

    @tag policies: [:broken_read_presence, :broken_write_presence]
    test "when a policy raises", context do
      use_authorize_function(true, 2)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :presence
               )
    end

    test "when a policy calls a function that does not exist", context do
      use_authorize_function(true)

      # plpgsql bodies are only resolved when run, so the missing function is only noticed by the check.
      # Restrictive, so it is evaluated on top of the permissive policy that grants the read.
      Postgrex.query!(
        context.db_conn,
        "CREATE OR REPLACE FUNCTION public.calls_missing_function() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN RETURN public.missing_function(); END $$",
        []
      )

      Postgrex.query!(
        context.db_conn,
        """
        CREATE POLICY "calls_missing_function" ON realtime.messages AS RESTRICTIVE FOR SELECT
        TO authenticated USING ( (SELECT public.calls_missing_function()) )
        """,
        []
      )

      assert {:error, :rls_policy_error,
              %Postgrex.Error{
                postgres: %{code: :undefined_function, message: "function public.missing_function() does not exist"}
              }} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the query raises", context do
      use_authorize_function(true)
      fail_function_with(%RuntimeError{message: "boom"})

      assert {:error, %RuntimeError{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the database connection fails", context do
      use_authorize_function(true)
      fail_function_with(%DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :closed})

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the pool times out", context do
      use_authorize_function(true)

      fail_function_with(%DBConnection.ConnectionError{
        message: "queue timeout",
        severity: :error,
        reason: :queue_timeout
      })

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the database process is gone", context do
      use_authorize_function(true)
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 pid,
                 context.authorization_context,
                 :broadcast
               )
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :slow_read]
    test "when the query is canceled", context do
      use_authorize_function(true)
      # A single-connection pool, so the timeout applies to the connection the check runs on.
      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      Postgrex.query!(db_conn, "SET statement_timeout = '100ms'", [])

      assert {:error, :query_canceled, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, db_conn, context.authorization_context)
    end

    test "when the messages partition is missing", context do
      use_authorize_function(true)

      %{rows: partitions} =
        Postgrex.query!(
          context.db_conn,
          "SELECT inhrelid::regclass::text FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
          []
        )

      for [partition] <- partitions, do: Postgrex.query!(context.db_conn, "DROP TABLE #{partition}", [])

      assert {:error, :missing_partition} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end
  end

  defp check_all(db_conn, authorization_context) do
    with {:ok, policies} <- Authorization.get_read_authorizations(%Policies{}, db_conn, authorization_context),
         {:ok, policies} <- Authorization.get_write_authorizations(policies, db_conn, authorization_context, :broadcast) do
      Authorization.get_write_authorizations(policies, db_conn, authorization_context, :presence)
    end
  end

  # Each Authorization check looks the flag up once
  defp use_authorize_function(enabled?, checks \\ 1) do
    expect(FeatureFlags, :enabled?, checks, fn "use_authorize_function", _tenant_id -> enabled? end)
  end

  defp fail_function_with(error, checks \\ 1),
    do: expect(Database, :query, checks, fn _, _, _, _, _ -> {:error, error} end)
end
