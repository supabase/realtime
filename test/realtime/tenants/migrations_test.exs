defmodule Realtime.Tenants.MigrationsTest do
  alias Realtime.Tenants.Cache
  # Can't use async: true because Cachex does not work well with Ecto Sandbox
  use Realtime.DataCase, async: false
  use Mimic

  alias Realtime.Tenants.Migrations

  describe "run_migrations/1" do
    test "migrations for a given tenant only run once" do
      tenant = Containers.checkout_tenant()

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

      assert Migrations.run_migrations(tenant) == :ok
      # Sleeping waiting for Cache to be invalided
      Process.sleep(100)
      assert Cache.get_tenant_by_external_id(tenant.external_id).migrations_ran == Enum.count(Migrations.migrations())
    end

    test "migrations do not run if tenant has migrations_ran at the count of all migrations" do
      tenant = tenant_fixture(%{migrations_ran: Enum.count(Migrations.migrations())})
      assert Migrations.run_migrations(tenant) == :noop
    end
  end

  describe "telemetry" do
    setup :set_mimic_global

    setup do
      events = [
        [:realtime, :tenants, :migrations, :start],
        [:realtime, :tenants, :migrations, :stop],
        [:realtime, :tenants, :migrations, :exception]
      ]

      :telemetry.attach_many(__MODULE__, events, &__MODULE__.handle_telemetry/4, pid: self())
      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      :ok
    end

    test "emits start event metadata" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id

      assert Migrations.run_migrations(tenant) == :ok

      assert_receive {:telemetry, [:realtime, :tenants, :migrations, :start], %{system_time: _},
                      %{external_id: ^external_id, hostname: hostname}}

      assert is_binary(hostname)
    end

    test "emits stop event with metadata" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id

      assert Migrations.run_migrations(tenant) == :ok

      total = Enum.count(Migrations.migrations())

      assert_receive {:telemetry, [:realtime, :tenants, :migrations, :stop], %{duration: duration},
                      %{external_id: ^external_id, hostname: hostname, migrations_executed: ^total}}

      assert is_binary(hostname)
      assert is_integer(duration) and duration >= 0
    end

    test "emits exception event tagged with postgrex error on postgres errors" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id

      error = %Postgrex.Error{postgres: %{code: :undefined_column}}
      expect(Ecto.Migrator, :run, fn _, _, _, _ -> raise error end)

      Migrations.run_migrations(tenant)

      assert_receive {:telemetry, [:realtime, :tenants, :migrations, :exception], %{duration: _},
                      %{external_id: ^external_id, error_code: :undefined_column, kind: :error, reason: ^error}}
    end

    test "tags connection errors with connection_error code" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id

      error = %DBConnection.ConnectionError{message: "ssl send: closed"}
      expect(Ecto.Migrator, :run, fn _, _, _, _ -> raise error end)

      Migrations.run_migrations(tenant)

      assert_receive {:telemetry, [:realtime, :tenants, :migrations, :exception], _,
                      %{external_id: ^external_id, error_code: :connection_error}}
    end
  end

  def handle_telemetry(event, measurements, metadata, pid: pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
