defmodule Realtime.Tenants.MigrationsTest do
  # async: false due to the fact that we're dropping database migrations
  use Realtime.DataCase, async: false

  alias Realtime.Database
  alias Realtime.Tenants.Migrations

  describe "run_migrations/1" do
    setup do
      tenant = tenant_fixture()
      %{tenant: tenant}
    end

    test "migrations for a given tenant only run once", %{tenant: tenant} do
      {:ok, conn} = Database.connect(tenant, "realtime_test")

      Postgrex.query!(conn, "DROP SCHEMA realtime CASCADE", [])
      Postgrex.query!(conn, "CREATE SCHEMA realtime", [])

      res =
        for _ <- 0..10 do
          Task.async(fn ->
            Migrations.run_migrations(tenant)
          end)
        end
        |> Task.await_many()
        |> Enum.uniq()

      assert [:ok] = res
    end
  end
end
