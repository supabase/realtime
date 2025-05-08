defmodule Containers do
  alias Containers.Container
  alias Realtime.Database
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Migrations

  def initialize(tenant) do
    name = "realtime-test-#{tenant.external_id}"
    %{port: port} = Database.from_tenant(tenant, "realtime_test", :stop)

    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--name",
        name,
        "-e",
        "POSTGRES_HOST=/var/run/postgresql",
        "-e",
        "POSTGRES_PASSWORD=postgres",
        "-p",
        "#{port}:5432",
        "supabase/postgres:15.8.1.040",
        "postgres",
        "-c",
        "config_file=/etc/postgresql/postgresql.conf"
      ])

    check_container_ready(name)

    Migrations.run_migrations(tenant)
    {:ok, pid} = Database.connect(tenant, "realtime_test", :stop)
    :ok = Migrations.create_partitions(pid)
    Process.exit(pid, :normal)

    tenant
  end

  @doc "Return port for a container that can be used"
  def checkout() do
    with container when is_pid(container) <- :poolboy.checkout(Containers, true, 5_000),
         port <- Container.port(container) do
      # Automatically checkin the container at the end of the test
      ExUnit.Callbacks.on_exit(fn -> :poolboy.checkin(Containers, container) end)

      {:ok, port}
    else
      _ -> {:error, "failed to checkout a container"}
    end
  end

  # Might be worth changing this to {:ok, tenant}
  def checkout_tenant(opts \\ []) do
    with container when is_pid(container) <- :poolboy.checkout(Containers, true, 5_000),
         port <- Container.port(container) do
      tenant = Generators.tenant_fixture(%{port: port, migrations_ran: 0})
      run_migrations? = Keyword.get(opts, :run_migrations, false)

      # Automatically checkin the container at the end of the test
      ExUnit.Callbacks.on_exit(fn -> :poolboy.checkin(Containers, container) end)

      settings = Database.from_tenant(tenant, "realtime_test", :stop)
      settings = %{settings | max_restarts: 0, ssl: false}
      {:ok, conn} = Database.connect_db(settings)

      Postgrex.transaction(conn, fn db_conn ->
        Postgrex.query!(
          db_conn,
          "SELECT pg_terminate_backend(pid) from pg_stat_activity where application_name like 'realtime_%' and application_name != 'realtime_test'",
          []
        )

        RateCounter.stop(tenant.external_id)
        GenCounter.stop(tenant.external_id)

        Postgrex.query!(db_conn, "DROP SCHEMA realtime CASCADE", [])
        Postgrex.query!(db_conn, "CREATE SCHEMA realtime", [])

        :ok
      end)

      if run_migrations? do
        case run_migrations(tenant) do
          {:ok, count} ->
            # Avoiding to use Tenants.update_migrations_ran/2 because it touches Cachex and it doesn't play well with
            # Ecto Sandbox
            {:ok, _} = Realtime.Api.update_tenant(tenant, %{migrations_ran: count})

          _ ->
            raise "Faled to run migrations"
        end

        :ok = Migrations.create_partitions(conn)
      end

      Process.exit(conn, :normal)

      tenant
    else
      _ -> {:error, "failed to checkout a container"}
    end
  end

  def stop_containers() do
    {list, 0} = System.cmd("docker", ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=realtime-test-*"])
    names = list |> String.trim() |> String.split("\n")

    for name <- names do
      System.cmd("docker", ["rm", "-f", name])
    end
  end

  defp check_container_ready(name, attempts \\ 50)
  defp check_container_ready(name, 0), do: raise("Container #{name} is not ready")

  defp check_container_ready(name, attempts) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-p", "5432", "-h", "localhost"]) do
      {_, 0} ->
        :ok

      {_, _} ->
        Process.sleep(500)
        check_container_ready(name, attempts - 1)
    end
  end

  # This exists so we avoid using an external process on Realtime.Tenants.Migrations
  defp run_migrations(tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant
    settings = Database.from_settings(settings, "realtime_migrations", :stop)

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
        opts = [all: true, prefix: "realtime", dynamic_repo: repo]
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
