defmodule RealtimeWeb.RlsAuthorizationTest do
  use RealtimeWeb.ConnCase

  import Plug.Conn

  alias Realtime.Tenants
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RlsAuthorization

  setup do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()
    settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)
    truncate_table(db_conn, "realtime.channels")
    channel_fixture(tenant)

    create_rls_policy(db_conn)

    on_exit(fn ->
      Postgrex.query!(db_conn, "drop policy select_authenticated_role on realtime.channels", [])
    end)

    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{jwt: jwt, claims: claims, tenant: tenant}
  end

  for {role, %{read: expected_read}} <- [
        {"anon", %{read: false}},
        {"authenticated", %{read: true}}
      ] do
    test "assigns the permissions correctly to #{role}", %{
      conn: conn,
      jwt: jwt,
      claims: claims,
      tenant: tenant
    } do
      conn =
        conn
        |> assign(:tenant, tenant)
        |> assign(:claims, claims)
        |> assign(:jwt, jwt)
        |> assign(:role, unquote(role))

      conn = RlsAuthorization.call(conn, %{})
      refute conn.halted
      assert conn.assigns.permissions == {:ok, %{read: unquote(expected_read)}}
    end
  end

  test "on error, halts the connection and set status to 401", %{
    conn: conn,
    jwt: jwt,
    claims: claims,
    tenant: tenant
  } do
    conn =
      conn
      |> assign(:tenant, tenant)
      |> assign(:claims, claims)
      |> assign(:jwt, jwt)
      |> assign(:role, "no")

    conn = RlsAuthorization.call(conn, %{})
    assert conn.halted
    assert conn.status == 401
  end

  defp create_rls_policy(conn) do
    Postgrex.query!(
      conn,
      """
      create policy select_authenticated_role
      on realtime.channels for select
      to authenticated
      using ( true );
      """,
      []
    )
  end
end
