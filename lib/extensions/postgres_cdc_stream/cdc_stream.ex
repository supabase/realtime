defmodule Extensions.PostgresCdcStream do
  @moduledoc false
  @behaviour Realtime.PostgresCdc

  require Logger
  import Realtime.Helpers, only: [log_error: 2]
  alias Extensions.PostgresCdcStream, as: Stream
  alias Realtime.Rpc

  def handle_connect(opts) do
    Enum.reduce_while(1..5, nil, fn retry, acc ->
      case get_manager_conn(opts["id"]) do
        {:error, nil} ->
          start_distributed(opts)
          if retry > 1, do: Process.sleep(1_000)
          {:cont, acc}

        {:ok, pid, _conn} ->
          {:halt, {:ok, pid}}
      end
    end)
  end

  def handle_after_connect(_, _, _) do
    {:ok, nil}
  end

  def handle_subscribe(pg_change_params, tenant, metadata) do
    Enum.each(pg_change_params, fn e ->
      tenant
      |> topic(e.params)
      |> RealtimeWeb.Endpoint.subscribe(metadata)
    end)
  end

  @doc """
  Stops the Supervision tree for a tenant.

  Expects an `external_id` as the `tenant`.
  """

  @spec handle_stop(String.t(), non_neg_integer()) :: :ok
  def handle_stop(tenant, timeout) when is_binary(tenant) do
    case :syn.lookup(PostgresCdcStream, tenant) do
      :undefined ->
        Logger.warning("Database supervisor not found for tenant #{tenant}")
        :ok

      {pid, _} ->
        DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  @spec get_manager_conn(String.t()) :: {:error, nil} | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    case Phoenix.Tracker.get_by_key(Stream.Tracker, "postgres_cdc_stream", id) do
      [] -> {:error, nil}
      [{_, %{manager_pid: pid, conn: conn}}] -> {:ok, pid, conn}
    end
  end

  def start_distributed(%{"region" => region, "id" => tenant} = args) do
    platform_region = Realtime.Nodes.platform_region_translator(region)
    launch_node = Realtime.Nodes.launch_node(tenant, platform_region, node())

    Logger.warning(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, platform_region: platform_region)}"
    )

    case Rpc.call(launch_node, __MODULE__, :start, [args], timeout: 30_000) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, _pid}} = error ->
        Logger.info("Postgres Extension already started on node #{inspect(launch_node)}")
        error

      error ->
        log_error("ErrorStartingPostgresCDCStream", error)
        error
    end
  end

  @doc """
  Start db poller. Expects an `external_id` as a `tenant`.
  """

  @spec start(map()) :: :ok | {:error, :already_started | :reserved}
  def start(%{"id" => tenant} = args) when is_binary(tenant) do
    Logger.debug("Starting #{__MODULE__} extension with args: #{inspect(args, pretty: true)}")

    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {Stream.DynamicSupervisor, self()}},
      %{
        id: tenant,
        start: {Stream.WorkerSupervisor, :start_link, [args]},
        restart: :transient
      }
    )
  end

  def topic(tenant, params) do
    "cdc_stream:" <> tenant <> ":" <> :erlang.term_to_binary(params)
  end

  def track_manager(id, pid, conn) do
    Phoenix.Tracker.track(
      Stream.Tracker,
      self(),
      "postgres_cdc_stream",
      id,
      %{
        conn: conn,
        manager_pid: pid
      }
    )
  end
end
