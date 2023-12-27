defmodule RealtimeWeb.RlsAuthorizationTest do
  use RealtimeWeb.ConnCase

  import Plug.Conn

  alias Realtime.Tenants
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RlsAuthorization

  setup context do
    start_supervised!(CurrentTime.Mock)
    tenant = tenant_fixture()

    settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
    settings = Map.put(settings, "id", tenant.external_id)
    settings = Map.put(settings, "db_socket_opts", [:inet])

    start_supervised!({Tenants.Migrations, settings})

    {:ok, db_conn} = Tenants.Connect.lookup_or_start_connection(tenant.external_id)

    clean_table(db_conn, "realtime", "channels")
    channel_fixture(tenant, context.rls_setup_params || %{})
    create_rls_policy(db_conn, context.rls, context.rls_setup_params)

    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    %{jwt: jwt, claims: claims, tenant: tenant}
  end

  @select_authenticated_role_tests [
    {"anon", :select_authenticated_role, nil, [], %{read: false}},
    {"authenticated", :select_authenticated_role, nil, [], %{read: true}}
  ]
  @select_authenticated_role_on_channel_name_tests [
    {
      "authenticated",
      :select_authenticated_role_on_channel_name,
      %{name: random_string()},
      [{"id", "1"}],
      %{read: true}
    },
    {
      "anon",
      :select_authenticated_role_on_channel_name,
      %{name: random_string()},
      [{"id", "1"}],
      %{read: false}
    }
  ]

  for {role, rls, rls_setup_params, conn_params, %{read: expected_read}} <-
        @select_authenticated_role_tests ++ @select_authenticated_role_on_channel_name_tests do
    @tag role: role, rls: rls, rls_setup_params: rls_setup_params
    test "assigns the permissions correctly to #{role} and #{rls} rule", %{
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
        |> Map.put(:path_params, unquote(conn_params) |> Map.new())

      conn = RlsAuthorization.call(conn, %{})
      refute conn.halted
      assert conn.assigns.permissions == {:ok, %{read: unquote(expected_read)}}
    end
  end

  @tag role: "authenticated", rls: :select_authenticated_role, rls_setup_params: nil
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
end
