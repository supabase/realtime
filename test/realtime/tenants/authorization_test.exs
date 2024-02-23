defmodule Realtime.Tenants.AuthorizationTest do
  # Needs to be false due to some conflicts when fetching connection from the pool since this use Postgrex directly
  use RealtimeWeb.ConnCase, async: false
  require Phoenix.ChannelTest

  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Permissions
  alias RealtimeWeb.Joken.CurrentTime
  alias Realtime.Channels

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    clean_table(db_conn, "realtime", "channels")
    channel = channel_fixture(tenant)

    create_rls_policy(db_conn, context.rls, channel)

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{channel: channel, db_conn: db_conn, jwt: jwt, claims: claims}
  end

  describe "get_authorizations for Plug.Conn" do
    @tag role: "authenticated", rls: :select_authenticated_role
    test "authenticated user has read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %Permissions{read: true}} = conn.assigns.permissions
    end

    @tag role: "anon", rls: :select_authenticated_role
    test "anon user has no read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %Permissions{read: false}} = conn.assigns.permissions
    end

    @tag role: "authenticated", rls: :write_authenticated_role
    test "authenticated user has write permissions and reverts check", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %Permissions{write: true}} = conn.assigns.permissions

      assert {:ok, %{check: nil}} = Channels.get_channel_by_name(channel.name, db_conn)
    end

    @tag role: "anon", rls: :write_authenticated_role
    test "anon user has no write permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %Permissions{write: false}} = conn.assigns.permissions
    end
  end

  describe "get_authorizations for Phoenix.Socket" do
    @tag role: "authenticated", rls: :select_authenticated_role
    test "authenticated user has read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %Permissions{read: true}} = conn.assigns.permissions
    end

    @tag role: "anon", rls: :select_authenticated_role
    test "anon user has no read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %Permissions{read: false}} = conn.assigns.permissions
    end

    @tag role: "authenticated", rls: :write_authenticated_role
    test "authenticated user has write permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %Permissions{write: true}} = conn.assigns.permissions
    end

    @tag role: "anon", rls: :write_authenticated_role
    test "anon user has no write permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params =
        Authorization.build_authorization_params(%{
          channel: channel,
          headers: [{"header-1", "value-1"}],
          jwt: jwt,
          claims: claims,
          role: role
        })

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %Permissions{write: false}} = conn.assigns.permissions
    end
  end

  @tag role: "non_existant", rls: :select_authenticated_role
  test "on error return error and unauthorized on channel", %{db_conn: db_conn} do
    params =
      Authorization.build_authorization_params(%{
        channel: nil,
        headers: [{"header-1", "value-1"}],
        jwt: "jwt",
        claims: %{},
        role: "non_existant"
      })

    {:error, :unauthorized} =
      Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)
  end
end
