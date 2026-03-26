defmodule RealtimeWeb.Dashboard.TenantInfoTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest
  import Generators

  setup do
    Application.put_env(:realtime, :dashboard_auth, :basic_auth)
    Application.put_env(:realtime, :dashboard_credentials, {"user", "pass"})

    on_exit(fn ->
      Application.delete_env(:realtime, :dashboard_auth)
      Application.delete_env(:realtime, :dashboard_credentials)
    end)

    tenant = tenant_fixture()
    conn = using_basic_auth(build_conn(), "user", "pass")

    %{tenant: tenant, conn: conn}
  end

  test "renders lookup form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info")

    assert html =~ "Tenant Info"
    assert html =~ "external_id"
  end

  test "shows tenant info for valid external_id via URL param", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    assert html =~ tenant.external_id
    assert html =~ tenant.name
    assert html =~ "postgres_cdc_rls"
  end

  test "shows tenant info for valid external_id via form submit", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{external_id: tenant.external_id})

    assert html =~ tenant.external_id
    assert html =~ tenant.name
    assert html =~ "postgres_cdc_rls"
  end

  test "shows error for unknown external_id via URL param", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=nonexistent")

    assert html =~ "Tenant not found"
  end

  test "shows error for unknown external_id via form submit", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{external_id: "nonexistent"})

    assert html =~ "Tenant not found"
  end

  test "does not show db_password", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    refute html =~ "db_password"
  end

  test "shows decrypted db_host", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    assert html =~ "127.0.0.1"
  end

  test "shows resolved db_host", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    assert html =~ "db_host_resolved"
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
