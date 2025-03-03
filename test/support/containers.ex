defmodule Containers do
  alias Realtime.Tenants
  alias Realtime.Database
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Migrations

  import ExUnit.CaptureLog
  defstruct [:port, :tenant, using?: false]

  @type t :: %__MODULE__{port: integer(), tenant: Realtime.Api.Tenant.t(), using?: boolean()}
  def initialize(tenant, lock? \\ false, run_migrations? \\ false) do
    capture_log(fn ->
      if :ets.whereis(:containers) == :undefined, do: :ets.new(:containers, [:named_table, :set, :public])

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
      check_select_possible(tenant)
      :ets.insert(:containers, {tenant.external_id, %{tenant: tenant, using?: lock?}})
    end)

    if run_migrations? do
      :ok = Migrations.run_migrations(tenant)
      {:ok, pid} = Database.connect(tenant, "realtime_test", :stop)
      :ok = Migrations.create_partitions(pid)
      Process.exit(pid, :normal)
    end

    tenant
  end

  def checkout_tenant(run_migrations? \\ false) do
    tenants = :ets.select(:containers, [{{:_, %{using?: :"$1", tenant: :"$2"}}, [{:==, :"$1", false}], [:"$2"]}])
    tenant = Enum.random(tenants)
    :ets.insert(:containers, {tenant.external_id, %{tenant: tenant, using?: true}})

    settings = Database.from_tenant(tenant, "realtime_test", :stop)
    settings = %{settings | max_restarts: 0, ssl: false}
    {:ok, conn} = Database.connect_db(settings)

    Postgrex.transaction(conn, fn db_conn ->
      pid = Connect.whereis(tenant.external_id)
      if pid && Process.alive?(pid), do: Connect.shutdown(tenant.external_id)

      tenant
      |> Tenants.limiter_keys()
      |> Enum.each(fn key ->
        RateCounter.stop(tenant.external_id)
        GenCounter.stop(tenant.external_id)
        RateCounter.new(key)
        GenCounter.new(key)
      end)

      Postgrex.query!(db_conn, "DROP SCHEMA realtime CASCADE", [])
      Postgrex.query!(db_conn, "CREATE SCHEMA realtime", [])

      :ok
    end)

    if run_migrations? do
      Migrations.run_migrations(tenant)
      {:ok, pid} = Database.connect(tenant, "realtime_test", :stop)
      Migrations.create_partitions(pid)
    end

    Process.exit(conn, :normal)
    tenant
  end

  def checkin_tenant(tenant) do
    :ets.insert(:containers, {tenant.external_id, %{tenant: tenant, using?: false}})
  end

  def stop_container(tenant) do
    :ets.delete(:containers, tenant.external_id)
    pid = Connect.whereis(tenant.external_id)
    if pid && Process.alive?(pid), do: Connect.shutdown(tenant.external_id)
    name = "realtime-test-#{tenant.external_id}"
    System.cmd("docker", ["rm", "-f", name])
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
    case System.cmd("docker", ["exec", name, "pg_isready"]) do
      {_, 0} ->
        :ok

      {_, _} ->
        Process.sleep(500)
        check_container_ready(name, attempts - 1)
    end
  end

  defp check_select_possible(tenant, attempts \\ 100)
  defp check_select_possible(_, 0), do: raise("Select is not possible")

  defp check_select_possible(tenant, attempts) do
    Process.flag(:trap_exit, true)

    settings =
      tenant
      |> Realtime.Database.from_tenant("realtime_check", :stop)
      |> Map.from_struct()
      |> Enum.to_list()
      |> Keyword.new()
      |> Keyword.put(:max_restarts, 0)
      |> Keyword.put(:ssl, false)
      |> Keyword.put(:log, false)

    {:ok, db_conn} = Postgrex.start_link(settings)

    case Postgrex.query(db_conn, "SELECT 1", []) do
      {:ok, _} ->
        :ok

      _ ->
        Process.sleep(500)
        check_select_possible(tenant, attempts - 1)
    end
  catch
    :exit, _ ->
      Process.sleep(500)
      check_select_possible(tenant, attempts - 1)

    _ ->
      Process.sleep(500)
      check_select_possible(tenant, attempts - 1)
  after
    Process.flag(:trap_exit, false)
  end
end
