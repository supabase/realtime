defmodule Realtime.Tenants.AuthorizationTest do
  # Needs to be false due to some conflicts when fetching connection from the pool since this use Postgrex directly

  use RealtimeWeb.ConnCase, async: false
  require Phoenix.ChannelTest

  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies

  alias RealtimeWeb.Joken.CurrentTime

  setup [:rls_context]

  describe "get_authorizations for Plug.Conn" do
    @tag role: "authenticated",
         policies: [:read_channel, :read_broadcast]
    test "authenticated user has expected policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               channel: %ChannelPolicies{read: true, write: false},
               broadcast: %BroadcastPolicies{read: true, write: false}
             } = conn.assigns.policies
    end

    @tag role: "anon",
         policies: [:read_channel, :write_channel, :read_broadcast, :write_broadcast]
    test "anon user has no policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ConnTest.build_conn(),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               channel: %ChannelPolicies{read: false, write: false},
               broadcast: %BroadcastPolicies{read: false, write: false}
             } = conn.assigns.policies
    end
  end

  describe "get_authorizations for Phoenix.Socket" do
    @tag role: "authenticated",
         policies: [:read_channel, :write_channel, :read_broadcast, :write_broadcast]
    test "authenticated user has expected policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               channel: %ChannelPolicies{read: true, write: true},
               broadcast: %BroadcastPolicies{read: true, write: true}
             } = conn.assigns.policies
    end

    @tag role: "anon",
         policies: [:read_channel, :write_channel, :read_broadcast, :write_broadcast]
    test "anon user has no policies", context do
      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          context.db_conn,
          context.authorization_context
        )

      assert %Policies{
               channel: %ChannelPolicies{read: false, write: false},
               broadcast: %BroadcastPolicies{read: false, write: false}
             } = conn.assigns.policies
    end
  end

  @tag role: "non_existant",
       policies: [:read_channel, :write_channel, :read_broadcast, :write_broadcast]
  test "on error return error and unauthorized on channel", %{db_conn: db_conn} do
    authorization_context =
      Authorization.build_authorization_params(%{
        channel: nil,
        headers: [{"header-1", "value-1"}],
        jwt: "jwt",
        claims: %{},
        role: "non_existant"
      })

    {:error, :unauthorized} =
      Authorization.get_authorizations(
        Phoenix.ConnTest.build_conn(),
        db_conn,
        authorization_context
      )
  end

  def rls_context(context) do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    clean_table(db_conn, "realtime", "broadcasts")
    clean_table(db_conn, "realtime", "channels")
    channel = channel_fixture(tenant)

    create_rls_policies(db_conn, context.policies, channel)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        channel: channel,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    %{
      channel: channel,
      db_conn: db_conn,
      authorization_context: authorization_context
    }
  end
end
