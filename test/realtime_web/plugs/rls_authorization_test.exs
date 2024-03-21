defmodule RealtimeWeb.RlsAuthorizationTest do
  # async: false due to the fact that multiple operations against the database will use the same connection
  use RealtimeWeb.ConnCase, async: false

  import Plug.Conn

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RlsAuthorization

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, _} = start_supervised({Connect, tenant_id: tenant.external_id}, restart: :transient)
    {:ok, db_conn} = Connect.get_status(tenant.external_id)

    clean_table(db_conn, "realtime", "channels")
    channel = channel_fixture(tenant)
    create_rls_policies(db_conn, context.policies, channel)

    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{jwt: jwt, claims: claims, tenant: tenant, channel: channel}
  end

  @tag role: "anon", policies: [:authenticated_read_channel]
  test "assigns the policies correctly to anon user",
       %{
         conn: conn,
         jwt: jwt,
         claims: claims,
         tenant: tenant,
         role: role,
         channel: channel
       } do
    conn =
      conn
      |> setup_conn(tenant, claims, jwt, role)
      |> Map.put(:path_params, %{"id" => channel.id})

    conn = RlsAuthorization.call(conn, %{})

    assert conn.assigns.policies == %Policies{channel: %ChannelPolicies{read: false}}
    refute conn.halted
  end

  @tag role: "authenticated", policies: [:authenticated_all_channels_read]
  test "assigns the policies correctly to authenticated user",
       %{
         conn: conn,
         jwt: jwt,
         claims: claims,
         tenant: tenant,
         role: role
       } do
    conn = setup_conn(conn, tenant, claims, jwt, role)
    conn = RlsAuthorization.call(conn, %{})

    assert conn.assigns.policies == %Policies{channel: %ChannelPolicies{read: true}}
    refute conn.halted
  end

  @tag role: "authenticated",
       policies: [
         :authenticated_all_channels_read,
         :authenticated_all_channels_insert
       ]
  test "assigns the policies correctly to authenticated user when channel name is in body",
       %{
         jwt: jwt,
         claims: claims,
         tenant: tenant,
         role: role
       } do
    conn =
      build_conn(:post, "", %{"name" => random_string()}) |> setup_conn(tenant, claims, jwt, role)

    conn = RlsAuthorization.call(conn, %{})

    assert conn.assigns.policies == %Policies{channel: %ChannelPolicies{read: true, write: true}}
    refute conn.halted
  end

  @tag role: "authenticated", policies: [:authenticated_read_channel]
  test "on error, halts the connection and set status to 401", %{
    conn: conn,
    jwt: jwt,
    claims: claims,
    tenant: tenant
  } do
    conn = setup_conn(conn, tenant, claims, jwt, "no")
    conn = RlsAuthorization.call(conn, %{})
    assert conn.status == 401
    assert conn.halted
  end

  defp setup_conn(conn, tenant, claims, jwt, role) do
    conn
    |> assign(:tenant, tenant)
    |> assign(:claims, claims)
    |> assign(:jwt, jwt)
    |> assign(:role, role)
  end
end
