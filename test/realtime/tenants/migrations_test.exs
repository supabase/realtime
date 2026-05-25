defmodule Realtime.Tenants.MigrationsTest do
  # Can't use async: true because Cachex does not work well with Ecto Sandbox
  use Realtime.DataCase, async: false
  use Mimic

  alias Realtime.Api
  alias Realtime.Database
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Migrations

  setup do
    Cachex.clear(Realtime.FeatureFlags.Cache)
    :ok
  end

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

  describe "migrations/1" do
    test "excludes SetupSupabaseRealtimeAdmin when the feature flag is disabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "use_supabase_realtime_admin", enabled: false})

      modules = Enum.map(Migrations.migrations(), fn {_v, m} -> m end)
      refute Migrations.SetupSupabaseRealtimeAdmin in modules
    end

    test "excludes SetupSupabaseRealtimeAdmin when the tenant override is disabled" do
      tenant = Containers.checkout_tenant()
      {:ok, _} = Api.upsert_feature_flag(%{name: "use_supabase_realtime_admin", enabled: true})
      {:ok, _} = Realtime.FeatureFlags.set_tenant_flag("use_supabase_realtime_admin", tenant.external_id, false)

      Process.sleep(100)
      Cache.invalidate_tenant_cache(tenant.external_id)

      modules = Enum.map(Migrations.migrations(tenant.external_id), fn {_v, m} -> m end)
      refute Migrations.SetupSupabaseRealtimeAdmin in modules
    end

    test "includes SetupSupabaseRealtimeAdmin when the feature flag is enabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "use_supabase_realtime_admin", enabled: true})

      modules = Enum.map(Migrations.migrations(), fn {_v, m} -> m end)
      assert Migrations.SetupSupabaseRealtimeAdmin in modules
    end

    test "includes SetupSupabaseRealtimeAdmin when the tenant override is enabled" do
      tenant = Containers.checkout_tenant()
      {:ok, _} = Api.upsert_feature_flag(%{name: "use_supabase_realtime_admin", enabled: false})
      {:ok, _} = Realtime.FeatureFlags.set_tenant_flag("use_supabase_realtime_admin", tenant.external_id, true)

      Process.sleep(100)
      Cache.invalidate_tenant_cache(tenant.external_id)

      modules = Enum.map(Migrations.migrations(tenant.external_id), fn {_v, m} -> m end)
      assert Migrations.SetupSupabaseRealtimeAdmin in modules
    end
  end

  describe "create_partitions/1" do
    test "reassigns ownership of existing partitions to supabase_realtime_admin" do
      tenant = Containers.checkout_tenant(run_migrations: true)
      {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)
      {:ok, conn} = Database.connect_db(%{settings | username: "supabase_admin", max_restarts: 0, ssl: false})

      # Pick a date inside the window create_partitions iterates over (today-1 .. today+3).
      date = Date.utc_today()
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      next_day = Date.to_string(Date.add(date, 1))
      start_day = Date.to_string(date)

      Postgrex.query!(conn, "DROP TABLE IF EXISTS realtime.#{partition_name}", [])

      Postgrex.query!(
        conn,
        """
        CREATE TABLE realtime.#{partition_name}
        PARTITION OF realtime.messages
        FOR VALUES FROM ('#{start_day}') TO ('#{next_day}')
        """,
        []
      )

      assert {:ok, %{rows: [["supabase_admin"]]}} = partition_owner(conn, partition_name)
      assert :ok = Migrations.create_partitions(conn)
      assert {:ok, %{rows: [["supabase_realtime_admin"]]}} = partition_owner(conn, partition_name)
    end
  end

  defp partition_owner(conn, name) do
    Postgrex.query(
      conn,
      """
      SELECT r.rolname FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_roles r ON r.oid = c.relowner
      WHERE n.nspname = 'realtime' AND c.relname = $1
      """,
      [name]
    )
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
