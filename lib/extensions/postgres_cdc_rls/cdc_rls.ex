defmodule Extensions.PostgresCdcRls do
  @moduledoc false
  @behaviour Realtime.PostgresCdc
  require Logger

  alias RealtimeWeb.Endpoint
  alias Realtime.PostgresCdc
  alias Extensions.PostgresCdcRls, as: Rls
  alias Rls.Subscriptions

  def handle_connect(args) do
    Enum.reduce_while(1..5, nil, fn retry, acc ->
      get_manager_conn(args["id"])
      |> case do
        nil ->
          start_distributed(args)
          if retry > 1, do: Process.sleep(1_000)
          {:cont, acc}

        :wait ->
          Process.sleep(1_000)
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
    case :syn.whereis_name({__MODULE__, tenant}) do
      :undefined ->
        Logger.warning("Database supervisor not found for tenant #{tenant}")

      pid ->
        DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  ## Internal functions

  def start_distributed(%{"region" => region, "id" => tenant} = args) do
    fly_region = PostgresCdc.aws_to_fly(region)
    launch_node = PostgresCdc.launch_node(tenant, fly_region, node())

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
        "subs_pool_size" => Map.get(args, "subcriber_pool_size", 5)
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

  @spec get_manager_conn(String.t()) :: nil | :wait | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    :syn.lookup(__MODULE__, id)
    |> case do
      {_, %{manager: nil, subs_pool: nil}} ->
        :wait

      {_, %{manager: manager, subs_pool: conn}} ->
        {:ok, manager, conn}

      _ ->
        nil
    end
  end

  def create_subscription(conn, publication, opts, timeout \\ 5_000) do
    conn_node = node(conn)

    if conn_node !== node() do
      :rpc.call(conn_node, Subscriptions, :create, [conn, publication, opts], timeout)
    else
      Subscriptions.create(conn, publication, opts)
    end
  end

  @spec supervisor_id(String.t(), String.t()) :: {atom(), String.t(), map()}
  def supervisor_id(tenant, region) do
    {
      __MODULE__,
      tenant,
      %{region: region, manager: nil, subs_pool: nil}
    }
  end

  @spec update_meta(String.t(), pid(), pid()) :: {:ok, {pid(), term()}} | {:error, term()}
  def update_meta(tenant, manager_pid, subs_pool) do
    :syn.update_registry(__MODULE__, tenant, fn pid, meta ->
      if node(pid) == node(manager_pid) do
        %{meta | manager: manager_pid, subs_pool: subs_pool}
      else
        Logger.error(
          "Node mismatch for tenant #{tenant} #{inspect(node(pid))} #{inspect(node(manager_pid))}"
        )

        meta
      end
    end)
  end
end
