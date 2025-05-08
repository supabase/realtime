defmodule Realtime.Tenants.AuthorizationTest do
  # async: false due to usage of mocks
  use RealtimeWeb.ConnCase, async: false

  require Phoenix.ChannelTest

  import Mock

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias RealtimeWeb.Joken.CurrentTime

  setup [:rls_context]

  describe "get_authorizations for Plug.Conn" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast,
           :authenticated_read_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, conn} =
        Authorization.get_read_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: nil},
               presence: %PresencePolicies{read: true, write: nil}
             } = conn.assigns.policies
    end

    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast
         ]
    test "authenticated user has expected mixed policies", context do
      {:ok, conn} =
        Authorization.get_read_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: nil},
               presence: %PresencePolicies{read: false, write: nil}
             } = conn.assigns.policies
    end

    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast,
           :authenticated_write_broadcast
         ]
    test "authenticated user has expected mixed extensions policies", context do
      {:ok, conn} =
        Authorization.get_read_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      {:ok, conn} =
        Authorization.get_write_authorizations(
          conn,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: false, write: false}
             } = conn.assigns.policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast,
           :authenticated_write_broadcast,
           :authenticated_read_presence,
           :authenticated_write_presence
         ]
    test "anon user has no policies", context do
      {:ok, conn} =
        Authorization.get_read_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      {:ok, conn} =
        Authorization.get_write_authorizations(
          conn,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } = conn.assigns.policies
    end
  end

  describe "get_authorizations for Phoenix.Socket" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, socket} =
        Authorization.get_read_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      {:ok, socket} =
        Authorization.get_write_authorizations(
          socket,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: true, write: true}
             } = socket.assigns.policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, socket} =
        Authorization.get_read_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      {:ok, socket} =
        Authorization.get_write_authorizations(
          socket,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } = socket.assigns.policies
    end
  end

  describe "get_write_authorizations for DBConnection" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(
          context.db_conn,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: true},
               presence: %PresencePolicies{read: nil, write: true}
             } = policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, policies} =
        Authorization.get_write_authorizations(
          context.db_conn,
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: nil, write: false},
               presence: %PresencePolicies{read: nil, write: false}
             } = policies
    end
  end

  describe "database error" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ],
         timeout: :timer.minutes(2)
    test "handles small pool size", context do
      task =
        Task.async(fn ->
          Postgrex.query!(context.db_conn, "SELECT pg_sleep(59)", [], timeout: :timer.minutes(1))
        end)

      Process.sleep(100)

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(
                 Phoenix.ConnTest.build_conn(),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 Phoenix.ConnTest.build_conn(),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_read_authorizations(
                 Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :increase_connection_pool} =
               Authorization.get_write_authorizations(
                 context.db_conn,
                 context.db_conn,
                 context.authorization_context
               )

      Task.await(task, :timer.minutes(1))
    end

    @tag role: "authenticated",
         policies: [:broken_read_presence, :broken_write_presence]
    test "broken RLS policy sets policies to false and shows error to user", context do
      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 Phoenix.ConnTest.build_conn(),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 Phoenix.ConnTest.build_conn(),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_read_authorizations(
                 Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
                 context.db_conn,
                 context.authorization_context
               )

      assert {:error, :rls_policy_error, %Postgrex.Error{}} =
               Authorization.get_write_authorizations(
                 context.db_conn,
                 context.db_conn,
                 context.authorization_context
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
      {:ok, socket} =
        Authorization.get_read_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      {:ok, _} =
        Authorization.get_write_authorizations(
          socket,
          context.db_conn,
          context.authorization_context
        )

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
      with_mock Realtime.Telemetry, execute: fn _, _, _ -> :ok end do
        {:ok, conn} =
          Authorization.get_read_authorizations(
            Phoenix.ConnTest.build_conn(),
            context.db_conn,
            context.authorization_context
          )

        {:ok, _} =
          Authorization.get_write_authorizations(
            conn,
            context.db_conn,
            context.authorization_context
          )

        assert_called(
          Realtime.Telemetry.execute(
            [:realtime, :tenants, :read_authorization_check],
            %{latency: :_},
            %{tenant_id: context.authorization_context.tenant_id}
          )
        )

        assert_called(
          Realtime.Telemetry.execute(
            [:realtime, :tenants, :write_authorization_check],
            %{latency: :_},
            %{tenant_id: context.authorization_context.tenant_id}
          )
        )
      end
    end
  end

  def rls_context(context) do
    start_supervised(CurrentTime.Mock)
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    topic = random_string()

    create_rls_policies(db_conn, context.policies, %{topic: topic})

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

    Realtime.Tenants.Migrations.create_partitions(db_conn)

    on_exit(fn -> Process.exit(db_conn, :kill) end)

    %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
