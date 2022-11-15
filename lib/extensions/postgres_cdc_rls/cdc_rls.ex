defmodule Extensions.PostgresCdcRls do
  @moduledoc false
  @behaviour Realtime.PostgresCdc
  require Logger

  alias RealtimeWeb.Endpoint
  alias Realtime.PostgresCdc
  alias Extensions.PostgresCdcRls, as: Rls
  alias Rls.{Subscriptions, SubscriptionManagerTracker}

  def handle_connect(args) do
    Enum.reduce_while(1..5, nil, fn retry, acc ->
      get_manager_conn(args["id"])
      |> case do
        nil ->
          start_distributed(args)
          if retry > 1, do: Process.sleep(1_000)
          {:cont, acc}

        {:ok, pid, conn} ->
          {:halt, {:ok, {pid, conn}}}
      end
    end)
  end

  def handle_after_connect({manager_pid, conn}, settings, params) do
    opts = params
    publication = settings["publication"]
    conn_node = node(conn)

    if conn_node !== node() do
      :rpc.call(conn_node, Subscriptions, :create, [conn, publication, opts], 15_000)
    else
      Subscriptions.create(conn, publication, opts)
    end
    |> case do
      {:ok, _} = response ->
        for %{id: id} <- params do
          send(manager_pid, {:subscribed, {self(), id}})
        end

        response

      other ->
        other
    end
  end

  def handle_subscribe(_, tenant, metadata) do
    Endpoint.subscribe("realtime:postgres:" <> tenant, metadata)
  end

  def handle_stop(tenant, timeout) do
    case :syn.lookup(Extensions.PostgresCdcRls, tenant) do
      :undefined ->
        Logger.warning("Database supervisor not found for tenant #{tenant}")

      {pid, _} ->
        DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  ## Internal functions

  def start_distributed(%{"region" => region, "id" => tenant} = args) do
    fly_region = PostgresCdc.aws_to_fly(region)
    launch_node = launch_node(tenant, fly_region, node())

    Logger.warning(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, fly_region: fly_region)}"
    )

    case :rpc.call(launch_node, __MODULE__, :start, [args], 30_000) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, _pid}} = error ->
        Logger.info("Postgres Extention already started on node #{inspect(launch_node)}")
        error

      error ->
        Logger.error("Error starting Postgres Extention: #{inspect(error, pretty: true)}")
        error
    end
  end

  @doc """
  Start db poller.

  """
  @spec start(map()) :: :ok | {:error, :already_started | :reserved}
  def start(args) do
    addrtype =
      case args["ip_version"] do
        6 ->
          :inet6

        _ ->
          :inet
      end

    args =
      Map.merge(args, %{
        "db_socket_opts" => [addrtype],
        "subs_pool_size" => Map.get(args, "subscriptions_pool", 5)
      })

    Logger.debug("Starting postgres stream extension with args: #{inspect(args, pretty: true)}")

    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {Rls.DynamicSupervisor, self()}},
      %{
        id: args["id"],
        start: {Rls.WorkerSupervisor, :start_link, [args]},
        restart: :transient
      }
    )
  end

  @spec get_manager_conn(String.t()) :: nil | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    Phoenix.Tracker.get_by_key(SubscriptionManagerTracker, "subscription_manager", id)
    |> case do
      [] ->
        nil

      [{_, %{manager_pid: pid, conn: conn}}] ->
        {:ok, pid, conn}
    end
  end

  def launch_node(tenant, fly_region, default) do
    case PostgresCdc.region_nodes(fly_region) do
      [_ | _] = regions_nodes ->
        member_count = Enum.count(regions_nodes)
        index = :erlang.phash2(tenant, member_count)
        {_, [node: launch_node]} = Enum.at(regions_nodes, index)
        launch_node

      _ ->
        Logger.warning("Didn't find launch_node, return default #{inspect(default)}")
        default
    end
  end

  def get_or_start_conn(args, retries \\ 5) do
    Enum.reduce_while(1..retries, nil, fn retry, acc ->
      get_manager_conn(args["id"])
      |> case do
        nil ->
          start_distributed(args)
          if retry > 1, do: Process.sleep(1_000)
          {:cont, acc}

        {:ok, _pid, _conn} = resp ->
          {:halt, resp}
      end
    end)
  end

  def create_subscription(conn, publication, opts, timeout \\ 5_000) do
    conn_node = node(conn)

    if conn_node !== node() do
      :rpc.call(conn_node, Subscriptions, :create, [conn, publication, opts], timeout)
    else
      Subscriptions.create(conn, publication, opts)
    end
  end

  def track_manager(id, pid, conn) do
    Phoenix.Tracker.track(SubscriptionManagerTracker, self(), "subscription_manager", id, %{
      conn: conn,
      manager_pid: pid
    })
  end
end
