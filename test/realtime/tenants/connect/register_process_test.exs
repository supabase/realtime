defmodule Realtime.Tenants.Connect.RegisterProcessTest do
  # Can't use async: true because Cachex does not work well with Ecto Sandbox
  use Realtime.DataCase, async: false
  alias Realtime.Tenants.Connect.RegisterProcess
  alias Realtime.Tenants.Connect

  describe "run/1" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)
      conn = start_supervised!({Connect, [tenant_id: tenant.external_id]})
      %{tenant_id: tenant.external_id, db_conn_pid: conn}
    end

    test "registers the process in :syn", %{tenant_id: tenant_id, db_conn_pid: conn} do
      assert {:ok, _} = RegisterProcess.run(%{tenant_id: tenant_id, db_conn_pid: conn})
    end

    test "handles undefined process error" do
      assert {:error, :process_not_found} =
               RegisterProcess.run(%{tenant_id: Generators.random_string(), db_conn_pid: nil})
    end
  end
end
