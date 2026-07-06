defmodule RealtimeWeb.Dashboard.TenantMigrationsTest do
  use RealtimeWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Realtime.Api
  alias Realtime.Database
  alias Realtime.Tenants.Migrations
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

  test "renders pg-delta section header with the resolved catalog major version", %{conn: conn, tenant: tenant} do
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

    %{rows: [[version]]} =
      Postgrex.query!(db_conn, "SELECT current_setting('server_version_num')::int / 10000", [])

    expected_major = if version >= 17, do: 17, else: 15

    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations?external_id=#{tenant.external_id}")

    assert has_element?(view, "h6", "pg-delta plan vs catalog (PG#{expected_major})")
  end

  test "shows 0 rows instead of an error when realtime.schema_migrations is missing", %{conn: conn, tenant: tenant} do
    {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)
    {:ok, admin_conn} = Database.connect_db(%{settings | username: "supabase_admin", pool_size: 1})
    Postgrex.query!(admin_conn, "DROP TABLE realtime.schema_migrations", [])

    {:ok, view, _html} = live(conn, "/admin/dashboard/tenant_migrations?external_id=#{tenant.external_id}")

    assert has_element?(view, "p.text-muted.small.mb-2", "0")
    refute has_element?(view, "p.text-danger")
  end

  describe "apply_pgdelta/2 with nil sql (backfill)" do
    test "inserts missing versions and updates tenants.migrations_ran", %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(
        db_conn,
        "DELETE FROM realtime.schema_migrations WHERE version > 20211116213934",
        []
      )

      {:ok, _} = Api.update_migrations_ran(tenant.external_id, 7)

      assert :ok = TenantMigrations.apply_pgdelta(tenant, nil)

      %{rows: [[count]]} =
        Postgrex.query!(db_conn, "SELECT count(*)::int FROM realtime.schema_migrations", [])

      total = length(Migrations.migrations())
      assert count == total

      updated = Api.get_tenant_by_external_id(tenant.external_id, use_replica?: false)
      assert updated.migrations_ran == total
    end

    test "running twice keeps the row count and migrations_ran stable", %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      total = length(Migrations.migrations())

      assert :ok = TenantMigrations.apply_pgdelta(tenant, nil)
      assert :ok = TenantMigrations.apply_pgdelta(tenant, nil)

      %{rows: [[count]]} =
        Postgrex.query!(db_conn, "SELECT count(*)::int FROM realtime.schema_migrations", [])

      assert count == total

      updated = Api.get_tenant_by_external_id(tenant.external_id, use_replica?: false)
      assert updated.migrations_ran == total
    end
  end

  describe "apply_pgdelta/2" do
    test "runs the sql plan and backfills schema_migrations", %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(
        db_conn,
        "DELETE FROM realtime.schema_migrations WHERE version > 20211116213934",
        []
      )

      {:ok, _} = Api.update_migrations_ran(tenant.external_id, 7)

      assert :ok = TenantMigrations.apply_pgdelta(tenant, "SELECT 1")

      %{rows: [[count]]} =
        Postgrex.query!(db_conn, "SELECT count(*)::int FROM realtime.schema_migrations", [])

      total = length(Migrations.migrations())
      assert count == total

      updated = Api.get_tenant_by_external_id(tenant.external_id, use_replica?: false)
      assert updated.migrations_ran == total
    end
  end

  describe "postgres_url/1" do
    test "builds a valid URL for IPv4 hosts" do
      assert TenantMigrations.postgres_url(%Database{
               hostname: "db.example.com",
               port: 5432,
               database: "postgres",
               username: "supabase_admin",
               password: "s3cr3t",
               socket_options: [:inet],
               ssl: true
             }) == "postgresql://supabase_admin:s3cr3t@db.example.com:5432/postgres?sslmode=require"
    end

    test "builds a valid URL for IPv6 hosts" do
      assert TenantMigrations.postgres_url(%Database{
               hostname: "2600:1f14:359d:9302:205d:38ca:a017:c7e3",
               port: 5432,
               database: "postgres",
               username: "supabase_admin",
               password: "s3cr3t",
               socket_options: [:inet6],
               ssl: true
             }) ==
               "postgresql://supabase_admin:s3cr3t@[2600:1f14:359d:9302:205d:38ca:a017:c7e3]:5432/postgres?sslmode=require"
    end

    test "builds a valid URL for DNS hostnames resolved over IPv6" do
      assert TenantMigrations.postgres_url(%Database{
               hostname: "db.example.com",
               port: 5432,
               database: "postgres",
               username: "supabase_admin",
               password: "s3cr3t",
               socket_options: [:inet6],
               ssl: true
             }) == "postgresql://supabase_admin:s3cr3t@db.example.com:5432/postgres?sslmode=require"
    end
  end

  defp using_basic_auth(conn, username, password) do
    header_content = "Basic " <> Base.encode64("#{username}:#{password}")
    put_req_header(conn, "authorization", header_content)
  end
end
