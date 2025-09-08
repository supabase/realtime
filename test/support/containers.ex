defmodule Containers do
  alias Extensions.PostgresCdcRls
  alias Realtime.Tenants.Connect
  alias Containers.Container
  alias Realtime.Database
  alias Realtime.RateCounter
  alias Realtime.Tenants.Migrations

  use GenServer

  @image "supabase/postgres:15.8.1.040"
  # Pull image if not available
  def pull do
    case System.cmd("docker", ["image", "inspect", @image]) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("Pulling image #{@image}. This might take a while...")
        {_, 0} = System.cmd("docker", ["pull", @image])
    end
  end

  def start_container(), do: GenServer.call(__MODULE__, :start_container, 10_000)
  def port(), do: GenServer.call(__MODULE__, :port, 10_000)

  def start_link(max_cases), do: GenServer.start_link(__MODULE__, max_cases, name: __MODULE__)

  def init(max_cases) do
    existing_containers = existing_containers("realtime-test-*")
    ports = for {_, port} <- existing_containers, do: port
    available_ports = Enum.shuffle(5501..9000) -- ports

    {:ok, %{existing_containers: existing_containers, ports: available_ports}, {:continue, {:pool, max_cases}}}
  end

  def handle_continue({:pool, max_cases}, state) do
    {:ok, _pid} =
      :poolboy.start_link(
        [name: {:local, Containers.Pool}, size: max_cases + 2, max_overflow: 0, worker_module: Containers.Container],
        []
      )

    {:noreply, state}
  end

  def handle_call(:port, _from, state) do
    [port | ports] = state.ports
    {:reply, port, %{state | ports: ports}}
  end

  def handle_call(:start_container, _from, state) do
    case state.existing_containers do
      [{name, port} | rest] ->
        {:reply, {:ok, name, port}, %{state | existing_containers: rest}}

      [] ->
        [port | ports] = state.ports
        name = "realtime-test-#{random_string(12)}"

        docker_run!(name, port)

        {:reply, {:ok, name, port}, %{state | ports: ports}}
    end
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end

  def initialize(external_id) do
    name = "realtime-tenant-test-#{external_id}"

    port =
      case existing_containers(name) do
        [{^name, port}] ->
          port

        [] ->
          port = 5500
          docker_run!(name, port)
          port
      end

    check_container_ready(name)

    opts = %{external_id: external_id, name: external_id, port: port, jwt_secret: "secure_jwt_secret"}
    tenant = Generators.tenant_fixture(opts)

    Migrations.run_migrations(tenant)
    {:ok, pid} = Database.connect(tenant, "realtime_test", :stop)
    :ok = Migrations.create_partitions(pid)
    Process.exit(pid, :normal)

    tenant
  end

  @doc "Return port for a container that can be used"
  def checkout() do
    with container when is_pid(container) <- :poolboy.checkout(Containers.Pool, true, 5_000),
         port <- Container.port(container) do
      # Automatically checkin the container at the end of the test
      ExUnit.Callbacks.on_exit(fn -> :poolboy.checkin(Containers.Pool, container) end)

      {:ok, port}
    else
      _ -> {:error, "failed to checkout a container"}
    end
  end

  # Might be worth changing this to {:ok, tenant}
  def checkout_tenant(opts \\ []) do
    with container when is_pid(container) <- :poolboy.checkout(Containers.Pool, true, 5_000),
         port <- Container.port(container) do
      tenant = Generators.tenant_fixture(%{port: port, migrations_ran: 0})
      run_migrations? = Keyword.get(opts, :run_migrations, false)

      settings = Database.from_tenant(tenant, "realtime_test", :stop)
      settings = %{settings | max_restarts: 0, ssl: false}
      {:ok, conn} = Database.connect_db(settings)

      Postgrex.transaction(conn, fn db_conn ->
        Postgrex.query!(db_conn, "DROP SCHEMA IF EXISTS realtime CASCADE", [])
        Postgrex.query!(db_conn, "CREATE SCHEMA IF NOT EXISTS realtime", [])
      end)

      Process.exit(conn, :normal)

      RateCounter.stop(tenant.external_id)

      # Automatically checkin the container at the end of the test
      ExUnit.Callbacks.on_exit(fn ->
        # Clean up database connections if they are set-up

        if connect_pid = Connect.whereis(tenant.external_id) do
          supervisor = {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, tenant.external_id}}

          DynamicSupervisor.terminate_child(supervisor, connect_pid)
        end

        try do
          PostgresCdcRls.handle_stop(tenant.external_id, 5_000)
        catch
          _, _ -> :ok
        end

        :poolboy.checkin(Containers.Pool, container)
      end)

      tenant =
        if run_migrations? do
          case run_migrations(tenant) do
            {:ok, count} ->
              # Avoiding to use Tenants.update_migrations_ran/2 because it touches Cachex and it doesn't play well with
              # Ecto Sandbox
              :ok = Migrations.create_partitions(conn)
              {:ok, tenant} = Realtime.Api.update_tenant(tenant, %{migrations_ran: count})
              tenant

            _ ->
              raise "Faled to run migrations"
          end
        else
          tenant
        end

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

  def stop_container(external_id) do
    name = "realtime-tenant-test-#{external_id}"
    System.cmd("docker", ["rm", "-f", name])
  end

  defp existing_containers(pattern) do
    {containers, 0} = System.cmd("docker", ["ps", "--format", "{{json .}}", "--filter", "name=#{pattern}"])

    containers
    |> String.split("\n", trim: true)
    |> Enum.map(fn container ->
      container = Jason.decode!(container)
      # Ports" => "0.0.0.0:6445->5432/tcp, [::]:6445->5432/tcp"
      regex = ~r/(?<=:)\d+(?=->)/

      [port] =
        Regex.scan(regex, container["Ports"])
        |> List.flatten()
        |> Enum.uniq()

      {container["Names"], String.to_integer(port)}
    end)
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

  defp docker_run!(name, port) do
    {_, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--rm",
        "--name",
        name,
        "-e",
        "POSTGRES_HOST=/var/run/postgresql",
        "-e",
        "POSTGRES_PASSWORD=postgres",
        "-p",
        "#{port}:5432",
        @image,
        "postgres",
        "-c",
        "config_file=/etc/postgresql/postgresql.conf",
        "-c",
        "wal_keep_size=32MB",
        "-c",
        "max_wal_size=32MB",
        "-c",
        "max_slot_wal_keep_size=32MB"
      ])
  end
end
