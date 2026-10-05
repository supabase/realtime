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

  describe "fallback to a transaction" do
    test "when realtime.authorize does not exist yet", context do
      use_authorize_function(true, 3)

      # Connect hands out the connection before the tenant migrations finish.
      fail_function_with(
        %Postgrex.Error{
          postgres: %{
            code: :undefined_function,
            message:
              "function realtime.authorize(unknown, unknown, unknown, unknown, unknown, unknown, unknown) does not exist"
          }
        },
        3
      )

      log =
        capture_log(fn -> assert {:ok, @all_allowed} = check_all(context.db_conn, context.authorization_context) end)

      assert log =~ "AuthorizeFunctionFallback"
    end

    test "when realtime.authorize returns an unexpected result", context do
      use_authorize_function(true, 3)
      expect(Database, :query, 3, fn _, _, _, _, _ -> {:ok, %Postgrex.Result{rows: [], num_rows: 0}} end)

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

      fail_function_with(%Postgrex.Error{
        postgres: %{code: :undefined_function, message: "function auth.missing() does not exist"}
      })

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
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
      fail_function_with({:exit, :noproc})

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 %Policies{},
                 context.db_conn,
                 context.authorization_context,
                 :broadcast
               )
    end

    test "when the query is canceled", context do
      use_authorize_function(true)

      fail_function_with(%Postgrex.Error{
        postgres: %{code: :query_canceled, message: "canceling statement due to statement timeout"}
      })

      assert {:error, :query_canceled, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(%Policies{}, context.db_conn, context.authorization_context)
    end

    test "when the messages partition is missing", context do
      use_authorize_function(true)

      fail_function_with(%Postgrex.Error{
        postgres: %{code: :check_violation, table: "messages", message: "no partition of relation \"messages\""}
      })

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
