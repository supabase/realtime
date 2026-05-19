defmodule RealtimeWeb.Dashboard.TenantMigrationsTest do
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Realtime.Database
  alias RealtimeWeb.Dashboard.TenantMigrations

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

  describe "postgres_url/1" do
    test "builds a valid URL for IPv4 hosts" do
      url =
        TenantMigrations.postgres_url(%Database{
          hostname: "db.example.com",
          port: 5432,
          database: "postgres",
          username: "supabase_admin",
          password: "s3cr3t",
          socket_options: [:inet],
          ssl: true
        })

      assert %URI{
               scheme: "postgresql",
               host: "db.example.com",
               port: 5432,
               path: "/postgres",
               userinfo: "supabase_admin:s3cr3t",
               query: "sslmode=require"
             } = URI.parse(url)
    end

    test "builds a valid URL for IPv6 hosts" do
      url =
        TenantMigrations.postgres_url(%Database{
          hostname: "2600:1f14:359d:9302:205d:38ca:a017:c7e3",
          port: 5432,
          database: "postgres",
          username: "supabase_admin",
          password: "s3cr3t",
          socket_options: [:inet6],
          ssl: true
        })

      assert url =~ "@[2600:1f14:359d:9302:205d:38ca:a017:c7e3]:5432/"

      assert %URI{
               scheme: "postgresql",
               host: "2600:1f14:359d:9302:205d:38ca:a017:c7e3",
               port: 5432,
               path: "/postgres"
             } = URI.parse(url)
    end
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
