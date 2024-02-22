defmodule Extensions.PostgresCdcRls do
  @moduledoc """
  Callbacks for initiating a Postgres connection and creating a Realtime subscription for database changes.
  """

  @behaviour Realtime.PostgresCdc
  require Logger

  alias RealtimeWeb.Endpoint
  alias Extensions.PostgresCdcRls, as: Rls
  alias Rls.Subscriptions
  alias Realtime.Rpc

  @spec handle_connect(map()) :: {:ok, {pid(), pid()}} | nil
  def handle_connect(args) do
    case get_manager_conn(args["id"]) do
      {:error, nil} ->
        start_distributed(args)
        nil

      {:error, :wait} ->
        nil

      {:ok, pid, conn} ->
        {:ok, {pid, conn}}
    end
  end

  def handle_after_connect({manager_pid, conn}, settings, params) do
    publication = settings["publication"]
    opts = [conn, publication, params, manager_pid, self()]
    conn_node = node(conn)

    if conn_node !== node() do
      Rpc.call(
        conn_node,
        Subscriptions,
        :create,
        opts,
        timeout: 15_000
      )
    else
      apply(Subscriptions, :create, opts)
    end
  end

  def handle_subscribe(_, tenant, metadata) do
    Endpoint.subscribe("realtime:postgres:" <> tenant, metadata)
  end

  def handle_stop(tenant, timeout) do
    case :syn.whereis_name({__MODULE__, tenant}) do
      :undefined -> Logger.warning("Database supervisor not found for tenant #{tenant}")
      pid -> DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  ## Internal functions

  def start_distributed(%{"region" => region, "id" => tenant} = args) do
    platform_region = Realtime.Nodes.platform_region_translator(region)
    launch_node = Realtime.Nodes.launch_node(tenant, platform_region, node())

    Logger.warning(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, platform_region: platform_region)}"
    )

    case Rpc.call(launch_node, __MODULE__, :start, [args], timeout: 30_000, tenant: tenant) do
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
    args = Map.merge(args, %{"subs_pool_size" => Map.get(args, "subcriber_pool_size", 5)})

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

  @spec get_manager_conn(String.t()) :: {:error, nil | :wait} | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    :syn.lookup(__MODULE__, id)
    |> case do
      {_, %{manager: nil, subs_pool: nil}} ->
        {:error, :wait}

      {_, %{manager: manager, subs_pool: conn}} ->
        {:ok, manager, conn}

      _ ->
        {:error, nil}
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
