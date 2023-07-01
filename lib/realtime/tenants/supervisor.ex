defmodule Realtime.Tenants.Manager do
  @moduledoc """
  Supervisor to manage Tenant database connection pools.
  """
  use Supervisor

  require Logger

  @partition_sup Realtime.Tenants.PartitionSupervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      {
        PartitionSupervisor,
        partitions: 20,
        child_spec: DynamicSupervisor,
        strategy: :one_for_one,
        name: @partition_sup
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_pool(args) do
    args =
      Map.merge(args, %{
        "db_socket_opts" => [addrtype(args)],
        "pool_size" => Map.get(args, "subcriber_pool_size", 5)
      })

    Logger.debug(
      "Starting tenant manager connection pool with args: #{inspect(args, pretty: true)}"
    )

    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {@partition_sup, args["id"]}},
      %{
        id: args["id"],
        start: {Realtime.Tenants.ConnectionPool, :start_link, [args]},
        restart: :transient
      }
    )
  end

  def pool_conn(args) do
    GenServer.whereis({:via, PartitionSupervisor, {@partition_sup, args["id"]}})
  end

  defp addrtype(args) do
    case args["ip_version"] do
      6 ->
        :inet6

      _ ->
        :inet
    end
  end
end
