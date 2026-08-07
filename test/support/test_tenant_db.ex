defmodule TestTenantDb do
  @moduledoc false
  # Backend-neutral pool of ready-to-use tenant databases for the test suite.

  alias Extensions.PostgresCdcRls
  alias Realtime.Tenants.Connect
  alias TestTenantDb.Backend
  alias Realtime.Database

  use GenServer

  def start_link(max_cases), do: GenServer.start_link(__MODULE__, max_cases, name: __MODULE__)

  # Dispense the next free TCP port. Used both as Generators.tenant_fixture/1's
  # default db_port (via Generators.port/0, when a test doesn't check out a
  # DB) and by the Docker backend when it needs a host port for a new
  # container. Ports are never handed out twice.
  def port(), do: GenServer.call(__MODULE__, :port, 10_000)

  def init(max_cases) do
    partition = System.get_env("MIX_TEST_PARTITION", "1") |> String.to_integer()
    total_partitions = System.get_env("MIX_TEST_TOTAL_PARTITIONS", "4") |> String.to_integer()
    all_ports = 6500..9000
    range_size = div(Enum.count(all_ports), total_partitions)

    # Exclude ports the backend has already reserved so we never hand out a port that's in use.
    reserved = Backend.current().reserved_ports()

    available_ports =
      all_ports |> Enum.slice((partition - 1) * range_size, range_size) |> Enum.shuffle() |> Kernel.--(reserved)

    {:ok, %{ports: available_ports}, {:continue, {:pool, max_cases}}}
  end

  def handle_continue({:pool, max_cases}, state) do
    {worker_module, size} = Backend.current().pool_spec(max_cases)

    {:ok, _pid} =
      :poolboy.start_link(
        [
          strategy: :fifo,
          name: {:local, TestTenantDb.Pool},
          size: size,
          max_overflow: 0,
          worker_module: worker_module
        ],
        []
      )

    {:noreply, state}
  end

  def handle_call(:port, _from, state) do
    [port | ports] = state.ports
    {:reply, port, %{state | ports: ports}}
  end

  @doc "Return a port for a pooled tenant DB that can be used"
  def checkout() do
    case acquire_tenant_db() do
      {:ok, port, checkin} ->
        # Automatically checkin at the end of the test
        ExUnit.Callbacks.on_exit(fn -> checkin.() end)
        {:ok, port}

      :error ->
        {:error, "failed to checkout a tenant database"}
    end
  end

  def checkout_tenant(opts \\ []), do: do_checkout_tenant(opts, :sandbox)
  def checkout_tenant_unboxed(opts \\ []), do: do_checkout_tenant(opts, :unboxed)

  # Acquire a tenant database for one test — a pooled supabase/postgres
  # container, or (in external mode) one of the pre-configured external DBs.
  # Either way it's a real pool checkout, released via the returned checkin
  # function once the caller is done.
  defp acquire_tenant_db do
    case :poolboy.checkout(TestTenantDb.Pool, true, 5_000) do
      worker when is_pid(worker) ->
        {:ok, Backend.current().worker_port(worker), fn -> :poolboy.checkin(TestTenantDb.Pool, worker) end}

      _ ->
        :error
    end
  end

  defp do_checkout_tenant(opts, mode) do
    with {:ok, port, checkin} <- acquire_tenant_db() do
      tenant = repo_run(mode, fn -> Generators.tenant_fixture(%{port: port, migrations_ran: 0}) end)

      run_migrations? = Keyword.get(opts, :run_migrations, false)

      {:ok, settings} = Database.from_tenant(tenant, "realtime_test", :stop)
      settings = %{settings | max_restarts: 0, ssl: false}
      {:ok, conn} = Database.connect_db(settings)

      try do
        reset_realtime_schema!(settings)
        Backend.current().storage_up!(tenant)

        RateCounterHelper.stop(tenant.external_id)

        ExUnit.Callbacks.on_exit(fn ->
          if connect_pid = Connect.whereis(tenant.external_id) do
            supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, tenant.external_id}}

            DynamicSupervisor.terminate_child(supervisor, connect_pid)
          end

          try do
            PostgresCdcRls.handle_stop(tenant.external_id, 5_000)
          catch
            _, _ -> :ok
          end

          if mode == :unboxed do
            repo_run(:unboxed, fn -> Realtime.Api.delete_tenant_by_external_id(tenant.external_id) end)
          end

          checkin.()
        end)

        if run_migrations? do
          case run_migrations(tenant) do
            {:ok, count} ->
              :ok = Realtime.Tenants.create_messages_partitions(conn)

              {:ok, tenant} =
                repo_run(mode, fn ->
                  Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{migrations_ran: count})
                end)

              if mode == :sandbox, do: Realtime.Tenants.Cache.invalidate_tenant_cache(tenant.external_id)

              tenant

            error ->
              raise "Failed to run migrations: #{inspect(error)}"
          end
        else
          tenant
        end
      after
        GenServer.stop(conn)
      end
    else
      :error -> {:error, "failed to checkout a tenant database"}
    end
  end

  defp repo_run(:unboxed, fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fun)
  defp repo_run(:sandbox, fun), do: fun.()

  # Reset the tenant DB's realtime schema to a clean slate before each test.
  # Backend-neutral: runs against whatever DB was checked out (both docker
  # and external servers are supabase/postgres-compatible). Mirrors the
  # supabase/postgres migrations.
  defp reset_realtime_schema!(settings, attempts \\ 5) do
    {:ok, admin_conn} =
      Postgrex.start_link(
        hostname: settings.hostname,
        port: settings.port,
        database: settings.database,
        username: "supabase_admin",
        password: settings.password
      )

    try do
      Postgrex.query!(admin_conn, "DROP PUBLICATION IF EXISTS supabase_realtime_test", [])
      Postgrex.query!(admin_conn, "DROP SCHEMA IF EXISTS realtime CASCADE", [])
      Postgrex.query!(admin_conn, "CREATE SCHEMA realtime", [])

      Postgrex.query!(admin_conn, "GRANT USAGE ON SCHEMA realtime TO postgres", [])
      Postgrex.query!(admin_conn, "GRANT ALL ON ALL TABLES IN SCHEMA realtime TO postgres, dashboard_user", [])
      Postgrex.query!(admin_conn, "GRANT ALL ON ALL SEQUENCES IN SCHEMA realtime TO postgres, dashboard_user", [])
      Postgrex.query!(admin_conn, "GRANT ALL ON ALL ROUTINES IN SCHEMA realtime TO postgres, dashboard_user", [])

      Postgrex.query!(
        admin_conn,
        "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON TABLES TO postgres, dashboard_user",
        []
      )

      Postgrex.query!(
        admin_conn,
        "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON SEQUENCES TO postgres, dashboard_user",
        []
      )

      Postgrex.query!(
        admin_conn,
        "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA realtime GRANT ALL ON ROUTINES TO postgres, dashboard_user",
        []
      )

      Postgrex.query!(admin_conn, "GRANT USAGE ON SCHEMA realtime TO anon, authenticated, service_role", [])
      Postgrex.query!(admin_conn, "GRANT ALL ON SCHEMA realtime TO supabase_realtime_admin WITH GRANT OPTION", [])
    rescue
      # Retry in case of OrioleDB OTablesMetaTranche LWLock
      e in [Postgrex.Error, DBConnection.ConnectionError] ->
        GenServer.stop(admin_conn)

        if attempts > 1 do
          Process.sleep(500)
          reset_realtime_schema!(settings, attempts - 1)
        else
          reraise e, __STACKTRACE__
        end
    after
      if Process.alive?(admin_conn), do: GenServer.stop(admin_conn)
    end
  end

  # This exists so we avoid using an external process on Realtime.Tenants.Migrations
  defp run_migrations(tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant
    {:ok, settings} = Database.from_settings(settings, "realtime_migrations", :stop)

    [
      hostname: settings.hostname,
      port: settings.port,
      database: settings.database,
      password: settings.password,
      username: settings.username,
      pool_size: settings.pool_size,
      backoff_type: settings.backoff_type,
      socket_options: settings.socket_options,
      parameters: [application_name: settings.application_name],
      ssl: settings.ssl
    ]
    |> Realtime.Repo.with_dynamic_repo(fn repo ->
      try do
        opts = [all: true, prefix: "realtime", dynamic_repo: repo, log: false]
        migrations = Realtime.Tenants.Migrations.migrations()
        Ecto.Migrator.run(Realtime.Repo, migrations, :up, opts)

        {:ok, length(migrations)}
      rescue
        error ->
          {:error, error}
      end
    end)
  end
end
