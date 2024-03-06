defmodule RealtimeWeb.RlsAuthorizationTest do
  use RealtimeWeb.ConnCase

  import Plug.Conn

  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.ChannelPolicies
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RlsAuthorization

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)

    clean_table(db_conn, "realtime", "channels")
    channel = channel_fixture(tenant)
    create_rls_policies(db_conn, context.policies, channel)

    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{jwt: jwt, claims: claims, tenant: tenant, channel: channel}
  end

  @tag role: "anon", policies: [:read_channel]
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
    refute conn.halted

    assert conn.assigns.policies == %Policies{channel: %ChannelPolicies{read: false}}
  end

  @tag role: "authenticated", policies: [:read_all_channels]
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
    refute conn.halted

    assert conn.assigns.policies == %Policies{channel: %ChannelPolicies{read: true}}
  end

  @tag role: "authenticated", policies: [:read_channel]
  test "on error, halts the connection and set status to 401", %{
    conn: conn,
    jwt: jwt,
    claims: claims,
    tenant: tenant
  } do
    conn = setup_conn(conn, tenant, claims, jwt, "no")
    conn = RlsAuthorization.call(conn, %{})
    assert conn.halted
    assert conn.status == 401
  end

  defp setup_conn(conn, tenant, claims, jwt, role) do
    conn
    |> assign(:tenant, tenant)
    |> assign(:claims, claims)
    |> assign(:jwt, jwt)
    |> assign(:role, role)
  end
end
