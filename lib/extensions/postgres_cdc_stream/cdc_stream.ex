defmodule Extensions.PostgresCdcStream do
  @moduledoc false
  @behaviour Realtime.PostgresCdc

  require Logger

  alias Realtime.PostgresCdc
  alias Extensions.PostgresCdcStream, as: Stream

  def handle_connect(opts) do
    Enum.reduce_while(1..5, nil, fn retry, acc ->
      get_manager_conn(opts["id"])
      |> case do
        nil ->
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
      topic(tenant, e.params)
      |> RealtimeWeb.Endpoint.subscribe(metadata)
    end)
  end

  def handle_stop(tenant, timeout) do
    case :syn.lookup(PostgresCdcStream, tenant) do
      :undefined ->
        Logger.warning("Database supervisor not found for tenant #{tenant}")

      {pid, _} ->
        DynamicSupervisor.stop(pid, :shutdown, timeout)
    end
  end

  @spec get_manager_conn(String.t()) :: nil | {:ok, pid(), pid()}
  def get_manager_conn(id) do
    Phoenix.Tracker.get_by_key(Stream.Tracker, "postgres_cdc_stream", id)
    |> case do
      [] ->
        nil

      [{_, %{manager_pid: pid, conn: conn}}] ->
        {:ok, pid, conn}
    end
  end

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
        "db_socket_opts" => [addrtype]
      })

    Logger.debug("Starting postgres stream extension with args: #{inspect(args, pretty: true)}")

    DynamicSupervisor.start_child(
      {:via, PartitionSupervisor, {Stream.DynamicSupervisor, self()}},
      %{
        id: args["id"],
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
