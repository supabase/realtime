defmodule Realtime.Tenants.AuthorizationTest do
  require Phoenix.ChannelTest
  use RealtimeWeb.ConnCase

  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias RealtimeWeb.Joken.CurrentTime

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(db_conn, "realtime.channels")
    channel = channel_fixture(tenant)

    case context do
      %{rls: policy} ->
        create_rls_policy(db_conn, policy)

        on_exit(fn ->
          Postgrex.query!(db_conn, "drop policy #{policy} on realtime.channels", [])
        end)

      _ ->
        :ok
    end

    claims = %{sub: random_string(), role: context.role, exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(claims, %{}, signer)

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
      params = %{
        channel_name: channel.name,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: role
      }

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %{read: true}} = conn.assigns.permissions
    end

    @tag role: "anon", rls: :select_authenticated_role
    test "anon user has no read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params = %{
        channel_name: channel.name,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: role
      }

      {:ok, conn} =
        Authorization.get_authorizations(Phoenix.ConnTest.build_conn(), db_conn, params)

      assert {:ok, %{read: false}} = conn.assigns.permissions
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
      params = %{
        channel_name: channel.name,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: role
      }

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %{read: true}} = conn.assigns.permissions
    end

    @tag role: "anon", rls: :select_authenticated_role
    test "anon user has no read permissions", %{
      channel: channel,
      db_conn: db_conn,
      jwt: jwt,
      claims: claims,
      role: role
    } do
      params = %{
        channel_name: channel.name,
        headers: [{"header-1", "value-1"}],
        jwt: jwt,
        claims: claims,
        role: role
      }

      {:ok, conn} =
        Authorization.get_authorizations(
          Phoenix.ChannelTest.socket(RealtimeWeb.UserSocket),
          db_conn,
          params
        )

      assert {:ok, %{read: false}} = conn.assigns.permissions
    end
  end

  defp create_rls_policy(conn, :select_authenticated_role) do
    Postgrex.query!(
      conn,
      """
      create policy select_authenticated_role
      on realtime.channels for select
      to authenticated
      using ( realtime.channel_name() = name );
      """,
      []
    )
  end
end
