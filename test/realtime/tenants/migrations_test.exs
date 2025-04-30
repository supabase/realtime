defmodule Realtime.Tenants.MigrationsTest do
  alias Realtime.Tenants.Cache
  use Realtime.DataCase, async: false

  alias Realtime.Tenants.Migrations

  describe "run_migrations/1" do
    test "migrations for a given tenant only run once" do
      tenant = Containers.checkout_tenant()
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      res =
        for _ <- 0..10 do
          Task.async(fn -> Migrations.run_migrations(tenant) end)
        end
        |> Task.await_many()
        |> Enum.uniq()

      assert [:ok] = res
    end

    test "migrations run if tenant has migrations_ran set to 0" do
      tenant = Containers.checkout_tenant()
      on_exit(fn -> Containers.checkin_tenant(tenant) end)

      assert Migrations.run_migrations(tenant) == :ok
      Process.sleep(100)
      assert Cache.get_tenant_by_external_id(tenant.external_id).migrations_ran == Enum.count(Migrations.migrations())
    end

    test "migrations do not run if tenant has migrations_ran at the count of all migrations" do
      tenant = tenant_fixture(%{migrations_ran: Enum.count(Migrations.migrations())})
      assert Migrations.run_migrations(tenant) == :noop
    end
  end
end
