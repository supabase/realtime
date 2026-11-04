defmodule Realtime.Tenants.Connect.RegisterProcessTest do
  use Realtime.DataCase, async: true
  alias Realtime.Tenants.Connect.RegisterProcess
  alias Realtime.Database

  describe "run/1" do
    setup do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test")
      %{tenant_id: tenant.external_id, db_conn_pid: conn}
    end

    test "registers the process in syn and Registry and updates metadata", %{tenant_id: tenant_id, db_conn_pid: conn} do
      # Fake the process registration in :syn
      :syn.register(Realtime.Tenants.Connect, tenant_id, self(), %{conn: nil, migrations_ran: nil})
      assert {:ok, _} = RegisterProcess.run(%{tenant_id: tenant_id, db_conn_pid: conn, migrations_ran_on_database: 3})
      assert {pid, %{conn: ^conn, migrations_ran: 3}} = :syn.lookup(Realtime.Tenants.Connect, tenant_id)
      assert [{^pid, %{}}] = Registry.lookup(Realtime.Tenants.Connect.Registry, tenant_id)
    end

    test "fails to register the process in syn and Registry and updates metadata", %{
      tenant_id: tenant_id,
      db_conn_pid: conn
    } do
      # Fake the process registration in :syn
      :syn.register(Realtime.Tenants.Connect, tenant_id, self(), %{conn: nil, migrations_ran: nil})

      # Register normally
      assert {:ok, _} = RegisterProcess.run(%{tenant_id: tenant_id, db_conn_pid: conn, migrations_ran_on_database: 0})
      assert {pid, %{conn: ^conn}} = :syn.lookup(Realtime.Tenants.Connect, tenant_id)
      assert [{^pid, %{}}] = Registry.lookup(Realtime.Tenants.Connect.Registry, tenant_id)

      # Check failure
      assert {:error, :already_registered} =
               RegisterProcess.run(%{tenant_id: tenant_id, db_conn_pid: conn, migrations_ran_on_database: 0})
    end

    test "handles undefined process error" do
      assert {:error, :process_not_found} =
               RegisterProcess.run(%{
                 tenant_id: Generators.random_string(),
                 db_conn_pid: nil,
                 migrations_ran_on_database: 0
               })
    end
  end
end
