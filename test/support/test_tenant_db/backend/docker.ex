defmodule TestTenantDb.Backend.Docker do
  @moduledoc false
  # Default backend: each pool worker runs a supabase/postgres docker
  # container. This module owns everything docker — image pull, `docker run`,
  # readiness probing, teardown — plus a small registry GenServer that hands
  # each TestTenantDb.Backend.Docker.Worker its container. New containers get
  # a host port from TestTenantDb's free-port dispenser; with
  # REUSE_CONTAINERS=true, already-running realtime-test-* containers are
  # handed out first (a dev speedup).
  @behaviour TestTenantDb.Backend

  use GenServer

  alias Realtime.Database
  alias Realtime.Env

  # -- TestTenantDb.Backend implementation

  @impl TestTenantDb.Backend
  def max_cases, do: Env.get_integer("MAX_CASES", 4)

  @impl TestTenantDb.Backend
  def prepare! do
    pull()

    existing =
      if Env.get_boolean("REUSE_CONTAINERS", false) do
        existing_containers()
      else
        stop_containers()
        []
      end

    {:ok, _pid} = GenServer.start_link(__MODULE__, existing, name: __MODULE__)
    :ok
  end

  @impl TestTenantDb.Backend
  def reserved_ports, do: GenServer.call(__MODULE__, :reserved_ports)

  # A couple of workers beyond max_cases so a test that briefly holds more
  # than one DB (or slow on_exit teardown) doesn't starve the pool.
  @impl TestTenantDb.Backend
  def pool_spec(max_cases), do: {__MODULE__.Worker, max_cases + 2}

  @impl TestTenantDb.Backend
  def worker_port(pid), do: __MODULE__.Worker.port(pid)

  @impl TestTenantDb.Backend
  def storage_up!(tenant) do
    {:ok, db_settings} = Database.from_tenant(tenant, "realtime_test", :stop)

    settings =
      db_settings
      |> Map.from_struct()
      |> Keyword.new()

    case Ecto.Adapters.Postgres.storage_up(settings) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      _ -> raise "Failed to create database"
    end
  end

  # -- Container registry (claimed by TestTenantDb.Backend.Docker.Worker)

  # Hand a worker a container: reuse a pre-existing one if any remain,
  # otherwise start a fresh one on a free port. Returns {:ok, name, port}.
  def claim, do: GenServer.call(__MODULE__, :claim, 30_000)

  @impl GenServer
  def init(existing), do: {:ok, %{existing: existing}}

  @impl GenServer
  def handle_call(:reserved_ports, _from, state) do
    {:reply, for({_name, port} <- state.existing, do: port), state}
  end

  def handle_call(:claim, _from, state) do
    case state.existing do
      [{name, port} | rest] ->
        {:reply, {:ok, name, port}, %{state | existing: rest}}

      [] ->
        {name, port} = start_available_container()
        {:reply, {:ok, name, port}, state}
    end
  end

  # -- Docker plumbing

  defp image, do: Env.get_binary("POSTGRES_IMAGE", "supabase/postgres:17.6.1.127")

  def pull do
    case System.cmd("docker", ["image", "inspect", image()]) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("Pulling image #{image()}. This might take a while...")
        {_, 0} = System.cmd("docker", ["pull", image()])
    end
  end

  # Start a container on a free port dispensed by TestTenantDb, retrying on a
  # fresh port if docker run fails (e.g. the port raced into use).
  defp start_available_container(attempts \\ 5)
  defp start_available_container(0), do: raise("TestTenantDb.Backend.Docker: exhausted retries starting a container")

  defp start_available_container(attempts) do
    port = TestTenantDb.port()
    name = container_name()

    case docker_run(name, port) do
      {_, 0} -> {name, port}
      {_output, _code} -> start_available_container(attempts - 1)
    end
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end

  def container_name, do: "#{TestEnv.container_prefix()}#{random_string(TestEnv.container_suffix_length())}"

  # Only containers this instance would have created: the docker name filter is a
  # substring match, so a custom TEST_CONTAINER_PREFIX that extends the default
  # (realtime-test-7-) is still matched by a default-prefixed run. Checking the
  # random suffix length keeps each instance from tearing down another's DBs.
  def own_container?(name) do
    prefix = TestEnv.container_prefix()

    String.starts_with?(name, prefix) and
      byte_size(name) == byte_size(prefix) + TestEnv.container_suffix_length()
  end

  def stop_containers() do
    {list, 0} =
      System.cmd("docker", ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=#{TestEnv.container_prefix()}"])

    for name <- String.split(list, "\n", trim: true), own_container?(name) do
      System.cmd("docker", ["rm", "-f", name])
    end
  end

  def existing_containers do
    {containers, 0} =
      System.cmd("docker", ["ps", "--format", "{{json .}}", "--filter", "name=#{TestEnv.container_prefix()}"])

    containers
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&own_container?(&1["Names"]))
    |> Enum.map(fn container ->
      # Ports" => "0.0.0.0:6445->5432/tcp, [::]:6445->5432/tcp"
      regex = ~r/(?<=:)\d+(?=->)/

      [port] =
        Regex.scan(regex, container["Ports"])
        |> List.flatten()
        |> Enum.uniq()

      {container["Names"], String.to_integer(port)}
    end)
  end

  def wait_ready!(name, attempts \\ 100)
  def wait_ready!(name, 0), do: raise("Container #{name} is not ready")

  def wait_ready!(name, attempts) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-p", "5432", "-h", "localhost"]) do
      {_, 0} ->
        :ok

      {_, _} ->
        Process.sleep(250)
        wait_ready!(name, attempts - 1)
    end
  end

  defp docker_run(name, port) do
    initdb_sh = Path.expand("../../../../dev/postgres/za-permit-supabase-admin.sh", __DIR__)
    initdb_sql = Path.expand("../../../../dev/postgres/zb-supabase-schema.sql", __DIR__)

    System.cmd(
      "docker",
      [
        "run",
        "-d",
        "--rm",
        "--name",
        name,
        "-e",
        "POSTGRES_HOST=/var/run/postgresql",
        "-e",
        "POSTGRES_PASSWORD=postgres",
        "-v",
        "#{initdb_sh}:/docker-entrypoint-initdb.d/za-permit-supabase-admin.sh",
        "-v",
        "#{initdb_sql}:/docker-entrypoint-initdb.d/zb-supabase-schema.sql",
        "-p",
        "#{port}:5432",
        image(),
        "postgres",
        "-c",
        "config_file=/etc/postgresql/postgresql.conf",
        "-c",
        "wal_keep_size=32MB",
        "-c",
        "max_wal_size=1GB",
        "-c",
        "max_slot_wal_keep_size=32MB"
      ],
      stderr_to_stdout: true
    )
  end
end
