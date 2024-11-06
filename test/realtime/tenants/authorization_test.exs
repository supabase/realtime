defmodule Realtime.Tenants.AuthorizationTest do
  # Needs to be false due to some conflicts when fetching connection from the pool since this use Postgrex directly
  use RealtimeWeb.ConnCase, async: false

  require Phoenix.ChannelTest

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Migrations

  alias RealtimeWeb.Joken.CurrentTime

  setup [:rls_context]

  describe "get_authorizations for Plug.Conn" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_topic,
           :authenticated_read_broadcast,
           :authenticated_read_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: false},
               presence: %PresencePolicies{read: true, write: false}
             } = conn.assigns.policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_topic,
           :authenticated_write_topic,
           :authenticated_read_broadcast,
           :authenticated_write_broadcast,
           :authenticated_read_presence,
           :authenticated_write_presence
         ]
    test "anon user has no policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ConnTest.build_conn(),
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
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: true, write: true},
               presence: %PresencePolicies{read: true, write: true}
             } = conn.assigns.policies
    end

    @tag role: "anon",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "anon user has no policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               broadcast: %BroadcastPolicies{read: false, write: false},
               presence: %PresencePolicies{read: false, write: false}
             } = conn.assigns.policies
    end
  end

  describe "ensure database stays clean" do
    @tag role: "authenticated",
         policies: [
           :authenticated_read_broadcast_and_presence,
           :authenticated_write_broadcast_and_presence
         ]
    test "authenticated user has expected policies", context do
      {:ok, _} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      {:ok, db_conn} = Database.connect(context.tenant, "realtime_test", 1)
      assert {:ok, []} = Repo.all(db_conn, Message, Message)
    end
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    [%{settings: settings} | _] = tenant.extensions
    migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}
    Migrations.run_migrations(migrations)

    {:ok, db_conn} = Database.connect(tenant, "realtime_test", 1)

    clean_table(db_conn, "realtime", "messages")
    topic = random_string()

    create_rls_policies(db_conn, context.policies, %{topic: topic})

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    Realtime.Tenants.Connect.CreatePartitions.run(%{db_conn_pid: db_conn})

    on_exit(fn -> Process.exit(db_conn, :normal) end)

    %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
