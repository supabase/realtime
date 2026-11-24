defmodule Realtime.Tenants.AuthorizationFunctionTest do
  # How Authorization uses the realtime.authorize function and when it falls back to a transaction.
  # The policies each one reports are covered by AuthorizationTest, which runs against both.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  import ExUnit.CaptureLog

  alias Realtime.Database
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

  setup [:checkout_tenant, :rls_context]

  describe "realtime.authorize" do
    test "checks each policy in a single query", context do
      reject(&Database.transaction/4)

      expect(Database, :query, 3, fn conn, statement, params, opts, metadata ->
        call_original(Database, :query, [conn, statement, params, opts, metadata])
      end)

      assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context)
    end

    test "role and request settings do not leak onto the connection", context do
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
      # Connect hands out the connection before the tenant migrations finish.
      Postgrex.query!(context.db_conn, "DROP FUNCTION realtime.authorize", [])

      # The fallback relies on a missing realtime.authorize being reported without a where
      assert {:error, %Postgrex.Error{postgres: %{code: :undefined_function} = postgres}} =
               Postgrex.query(context.db_conn, "SELECT * FROM realtime.authorize(role_name => 'anon')", [])

      refute Map.has_key?(postgres, :where)

      log =
        capture_log(fn -> assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context) end)

      assert log =~ "AuthorizeFunctionFallback"
    end

    test "when realtime.authorize returns an unexpected result", context do
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
                postgres: %{
                  code: :undefined_function,
                  message: "function public.missing_function() does not exist",
                  where: "PL/pgSQL function " <> _
                }
              }} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the query raises", context do
      fail_function_with(%RuntimeError{message: "boom"})

      assert {:error, %RuntimeError{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when a header is not valid UTF-8", context do
      reject(&Database.query/5)
      authorization_context = %{context.authorization_context | headers: [{"x-header", <<0xFF>>}]}

      assert {:error, %Jason.EncodeError{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, authorization_context)

      assert {:error, %Jason.EncodeError{}} =
               Authorization.get_write_authorizations(%Policies{}, context.db_conn, authorization_context, :broadcast)
    end

    test "when the database connection fails", context do
      fail_function_with(%DBConnection.ConnectionError{message: "ssl recv: closed", severity: :error, reason: :closed})

      assert {:error, :tenant_database_unavailable} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the pool times out", context do
      fail_function_with(%DBConnection.ConnectionError{
        message: "queue timeout",
        severity: :error,
        reason: :queue_timeout
      })

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the database process is gone", context do
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
      # A single-connection pool, so the timeout applies to the connection the check runs on.
      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test")
      Postgrex.query!(db_conn, "SET statement_timeout = '100ms'", [])

      assert {:error, :query_canceled, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, db_conn, context.authorization_context)
    end

    test "when the messages partition is missing", context do
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

  defp fail_function_with(error, checks \\ 1),
    do: expect(Database, :query, checks, fn _, _, _, _, _ -> {:error, error} end)
end
