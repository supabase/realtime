defmodule RealtimeWeb.Dashboard.TenantMigrationsTest do
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    Application.put_env(:realtime, :dashboard_auth, :basic_auth)
    Application.put_env(:realtime, :dashboard_credentials, {"user", "pass"})

    on_exit(fn ->
      Application.delete_env(:realtime, :dashboard_auth)
      Application.delete_env(:realtime, :dashboard_credentials)
    end)

    tenant = Containers.checkout_tenant(run_migrations: true)
    conn = using_basic_auth(build_conn(), "user", "pass")

    %{tenant: tenant, conn: conn}
  end

  test "renders lookup form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations")

    assert has_element?(view, "h5.card-title", "Tenant Migrations")
    assert has_element?(view, "input[name=external_id]")
    assert has_element?(view, "button[type=submit]", "Lookup")
  end

  test "shows schema_migrations for valid external_id via URL param", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations?external_id=#{tenant.external_id}")

    assert has_element?(view, "h6", "realtime.schema_migrations")
    assert has_element?(view, "th", "version")
    assert has_element?(view, "th", "inserted_at")
  end

  test "shows schema_migrations for valid external_id via form submit", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations")

    view
    |> element("form[phx-submit=lookup]")
    |> render_submit(%{external_id: tenant.external_id})

    assert has_element?(view, "h6", "realtime.schema_migrations")
    assert has_element?(view, "th", "version")
  end

  test "shows error for unknown external_id via URL param", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations?external_id=nonexistent")

    assert has_element?(view, "p.text-danger", "Tenant not found")
  end

  test "shows error for unknown external_id via form submit", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations")

    view
    |> element("form[phx-submit=lookup]")
    |> render_submit(%{external_id: "nonexistent"})

    assert has_element?(view, "p.text-danger", "Tenant not found")
  end

  test "renders pg-delta section header when tenant is found", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations?external_id=#{tenant.external_id}")

    assert has_element?(view, "h6", "pg-delta plan vs baseline")
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
