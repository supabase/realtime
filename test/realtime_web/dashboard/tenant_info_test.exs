defmodule RealtimeWeb.Dashboard.TenantInfoTest do
  use RealtimeWeb.ConnCase
  import Phoenix.LiveViewTest
  import Mimic

  alias Extensions.PostgresCdcRls
  alias Realtime.Nodes
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

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

  test "shows runtime status for connect and replication", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    assert html =~ "Runtime"
    assert html =~ "connect"
    assert html =~ "replication_connection"
    # Tenant is not connected in this test so both show as not connected
    assert html =~ "not connected"
  end

  test "shows connected users per region with cluster total", %{conn: conn, tenant: tenant} do
    {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    assert html =~ "Connected users per region"
    assert html =~ "total (cluster)"
  end

  test "auto-refresh recomputes runtime info", %{conn: conn, tenant: tenant} do
    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

    # Simulate the dashboard's "refresh every" tick
    send(view.pid, :refresh)

    html = render(view)
    assert html =~ "Runtime"
    assert html =~ "Connected users per region"
  end

  describe "runtime info with mocked status" do
    setup :set_mimic_global

    test "shows connect, replication and cdc_rls as up with their node", %{conn: conn, tenant: tenant} do
      manager = self()
      conn_pid = self()
      replication = self()
      connect = self()

      stub(Connect, :whereis, fn _ -> connect end)
      stub(Connect, :replication_status, fn _ -> {:ok, replication} end)
      stub(PostgresCdcRls, :get_manager_conn, fn _ -> {:ok, manager, conn_pid} end)

      {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

      assert html =~ "Runtime"
      # All three processes live on the test node
      assert html =~ "up"
      refute html =~ "not connected"
      assert html =~ to_string(node())
    end

    test "shows replication and cdc_rls as not connected when down", %{conn: conn, tenant: tenant} do
      connect = self()

      stub(Connect, :whereis, fn _ -> connect end)
      stub(Connect, :replication_status, fn _ -> {:error, :not_connected} end)
      stub(PostgresCdcRls, :get_manager_conn, fn _ -> {:error, :wait} end)

      {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

      assert html =~ "up"
      assert html =~ "not connected"
    end

    test "shows connected users summed per region from census", %{conn: conn, tenant: tenant} do
      stub(Nodes, :all_node_regions, fn -> ["us-east-1", "eu-west-2"] end)

      stub(Nodes, :region_nodes, fn
        "us-east-1" -> [:"node-a", :"node-b"]
        "eu-west-2" -> [:"node-c"]
      end)

      stub(UsersCounter, :tenant_users, fn
        _tenant, :"node-a" -> 3
        _tenant, :"node-b" -> 4
        _tenant, :"node-c" -> 5
      end)

      stub(UsersCounter, :tenant_users, fn _tenant -> 12 end)

      {:ok, _view, html} = live(conn, "/admin/dashboard/tenant_info?external_id=#{tenant.external_id}")

      assert html =~ "Connected users per region"

      rows = region_rows(html)

      # {region, nodes, connected} — us-east-1: 3 + 4 = 7 over 2 nodes, eu-west-2: 5 over 1 node
      assert {"us-east-1", "2", "7"} in rows
      assert {"eu-west-2", "1", "5"} in rows
      # cluster total comes straight from UsersCounter.tenant_users/1
      assert {"total (cluster)", "", "12"} in rows
    end
  end

  # Extracts the {region, nodes, connected} cells from the "Connected users per
  # region" table so assertions target the actual row instead of loose substrings.
  defp region_rows(html) do
    {:ok, document} = Floki.parse_document(html)

    document
    |> Floki.find("table")
    |> Enum.find(fn table ->
      Floki.find(table, "thead th") |> Floki.text() =~ "connected"
    end)
    |> Floki.find("tbody tr")
    |> Enum.map(fn row ->
      [region, nodes, connected] =
        row |> Floki.find("td") |> Enum.map(&(Floki.text(&1) |> String.trim()))

      {region, nodes, connected}
    end)
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
