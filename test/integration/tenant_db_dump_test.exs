defmodule Realtime.Integration.TenantDbDumpTest do
  use Realtime.DataCase, async: false

  alias Containers
  alias Realtime.Tenants.Migrations

  test "loads the bundled dump for a brand-new tenant" do
    tenant = Containers.checkout_tenant()

    :telemetry.attach(
      "tenant-db-dump-test",
      [:realtime, :tenants, :migrations, :stop],
      fn _event, _measurements, metadata, %{pid: pid} ->
        send(pid, {:migrations_executed, metadata.migrations_executed})
      end,
      %{pid: self()}
    )

    on_exit(fn -> :telemetry.detach("tenant-db-dump-test") end)

    assert Migrations.run_migrations(tenant) == :ok
    assert_receive {:migrations_executed, executed}
    assert executed == Enum.count(Migrations.migrations(tenant.external_id))
  end
end
