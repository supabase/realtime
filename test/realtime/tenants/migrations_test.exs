defmodule Realtime.Tenants.MigrationsTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Migrations

  describe "run_migrations/1" do
    setup do
      tenant = Containers.checkout_tenant()
      on_exit(fn -> Containers.checkin_tenant(tenant) end)
      %{tenant: tenant}
    end

    test "migrations for a given tenant only run once", %{tenant: tenant} do
      res =
        for _ <- 0..10 do
          Task.async(fn -> Migrations.run_migrations(tenant) end)
        end
        |> Task.await_many()
        |> Enum.uniq()

      assert [:ok] = res
    end
  end
end
