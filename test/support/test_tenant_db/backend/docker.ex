defmodule TestTenantDb.Backend.Docker do
  @moduledoc false
  # Default backend: each pool worker runs a supabase/postgres docker
  # container. This module owns everything docker — image pull, `docker run`,
  # readiness probing, teardown — plus a small registry GenServer that hands
  # each TestTenantDb.Backend.Docker.Worker its container. Docker picks the host
  # port, so no two runs can pick the same one; container names carry this run's
  # id, so startup only reaps containers whose owning run is gone. With
  # REUSE_CONTAINERS=true this run's own containers are handed out first
  # (a dev speedup).
  @behaviour TestTenantDb.Backend

  use GenServer

  alias Realtime.Database
  alias Realtime.Env

  @container_prefix "realtime-test"
  @container_suffix_length 12

  # -- TestTenantDb.Backend implementation

  @impl TestTenantDb.Backend
  def max_cases, do: Env.get_integer("MAX_CASES", 4)

  @impl TestTenantDb.Backend
  def prepare! do
    :ok = pull()

    reap_abandoned_containers()

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

  defp image, do: Env.get_binary("POSTGRES_IMAGE", "supabase/postgres:17.6.1.166")

  def pull do
    case System.cmd("docker", ["image", "inspect", image()]) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts("Pulling image #{image()}. This might take a while...")
        {_, 0} = System.cmd("docker", ["pull", image()])
        :ok
    end
  end

  # A container outside the pool, for a test that needs postgres settings the pooled ones
  # don't carry. Ready to take connections when it returns.
  @impl TestTenantDb.Backend
  def start_database!(postgres_args) do
    :ok = pull()
    {name, port} = start_available_container(postgres_args: postgres_args)
    wait_ready!(name)
    cleanup = fn -> remove_container(name) end

    {port, cleanup}
  end

  defp remove_container(name) do
    {_, 0} = System.cmd("docker", ["rm", "-f", name])
    :ok
  end

  # Start a container and let docker publish 5432 on a port of its choosing, then read the
  # port back: nothing else on the machine can be handed the same one.
  #
  # Options: `:postgres_args` (extra `-c` settings) and `:attempts` (tries left).
  defp start_available_container(opts \\ []) do
    postgres_args = Keyword.get(opts, :postgres_args, [])
    attempts = Keyword.get(opts, :attempts, 5)
    name = container_name()

    case docker_run(name, postgres_args) do
      {_, 0} ->
        {name, published_port!(name)}

      {_output, _code} when attempts > 1 ->
        start_available_container(Keyword.put(opts, :attempts, attempts - 1))

      {output, _code} ->
        raise "TestTenantDb.Backend.Docker: exhausted retries starting a container: #{output}"
    end
  end

  # "0.0.0.0:32768" / "[::]:32768" — take the first mapping's port.
  defp published_port!(name) do
    {output, 0} = System.cmd("docker", ["port", name, "5432/tcp"])

    case Regex.run(~r/:(\d+)\s*$/m, output) do
      [_, port] -> String.to_integer(port)
      nil -> raise "could not read the published port of #{name} from #{inspect(output)}"
    end
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end

  # This run's containers carry its run tag, so a run only ever tears down its own.
  def container_prefix, do: @container_prefix <> TestEnv.run_tag()

  def container_name, do: "#{container_prefix()}-#{random_string(@container_suffix_length)}"

  # The docker name filter is a substring match: a run listing "realtime-test" also gets another
  # run's "realtime-test_4003-...". A container is this run's only if its name is exactly this
  # run's prefix followed by a random suffix.
  def own_container?(name) do
    prefix = container_prefix() <> "-"

    String.starts_with?(name, prefix) and byte_size(name) == byte_size(prefix) + @container_suffix_length
  end

  # A run whose tag is its endpoint port is gone once that port is free again. A named run
  # (TEST_RUN) says nothing about liveness, so its containers are left for its owner.
  def abandoned_container?(name) do
    case Regex.run(~r/^#{@container_prefix}_(\d+)-(.+)$/, name) do
      [_, port, suffix] when byte_size(suffix) == @container_suffix_length ->
        Env.port_available?(String.to_integer(port))

      _ ->
        false
    end
  end

  # Containers left behind by runs that are gone. Whoever starts next clears them, so a killed
  # run doesn't leak databases forever.
  def reap_abandoned_containers do
    {list, 0} = System.cmd("docker", ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=#{@container_prefix}"])

    for name <- String.split(list, "\n", trim: true), abandoned_container?(name) do
      System.cmd("docker", ["rm", "-f", name])
    end
  end

  def stop_containers() do
    {list, 0} =
      System.cmd("docker", ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=#{container_prefix()}"])

    for name <- String.split(list, "\n", trim: true), own_container?(name) do
      System.cmd("docker", ["rm", "-f", name])
    end
  end

  def existing_containers do
    {containers, 0} =
      System.cmd("docker", ["ps", "--format", "{{json .}}", "--filter", "name=#{container_prefix()}"])

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

  # Each probe is a `docker exec` costing ~50ms, and the pool starts its containers at once,
  # so probing tighter than this trades overshoot on the successful probe for exec storms.
  @ready_probe_interval 100
  @ready_timeout to_timeout(second: 60)

  def wait_ready!(name), do: wait_ready!(name, System.monotonic_time(:millisecond) + @ready_timeout)

  defp wait_ready!(name, deadline) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-p", "5432", "-h", "localhost"]) do
      {_, 0} ->
        :ok

      {output, _} ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("Container #{name} is not ready: #{output}")

        Process.sleep(@ready_probe_interval)
        wait_ready!(name, deadline)
    end
  end

  defp docker_run(name, postgres_args) do
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
        "0:5432",
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
      ] ++ postgres_args,
      stderr_to_stdout: true
    )
  end
end
