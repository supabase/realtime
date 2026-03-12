defmodule Realtime.Dashboard.TenantInfoTest do
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
    assert html =~ "project_ref"
  end

  test "shows tenant info for valid project ref", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{project_ref: tenant.external_id})

    assert html =~ tenant.external_id
    assert html =~ tenant.name
    assert html =~ "postgres_cdc_rls"
  end

  test "shows error for unknown project ref", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{project_ref: "nonexistent"})

    assert html =~ "Tenant not found"
  end

  test "does not show db_password", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{project_ref: tenant.external_id})

    refute html =~ "db_password"
  end

  test "shows decrypted db_host", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info")

    html = view |> element("form[phx-submit='lookup']") |> render_submit(%{project_ref: tenant.external_id})

    assert html =~ "127.0.0.1"
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
