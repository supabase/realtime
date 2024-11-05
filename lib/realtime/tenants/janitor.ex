defmodule Realtime.Tenants.Janitor do
  @moduledoc """
  Scheduled tasks for the Tenants.
  """

  use GenServer
  require Logger

  import Ecto.Query
  import Realtime.Helpers, only: [log_error: 2]

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Nodes
  alias Realtime.Repo

  @type t :: %__MODULE__{
          timer: pos_integer() | nil,
          region: String.t() | nil,
          chunks: pos_integer() | nil,
          start_after: pos_integer() | nil,
          randomize: boolean() | nil,
          tasks: map()
        }

  defstruct timer: nil,
            region: nil,
            chunks: nil,
            start_after: nil,
            randomize: nil,
            tasks: %{}

  def start_link(_args) do
    timer = Application.get_env(:realtime, :janitor_schedule_timer)
    start_after = Application.get_env(:realtime, :janitor_run_after_in_ms, 0)
    chunks = Application.get_env(:realtime, :janitor_chunk_size)
    randomize = Application.get_env(:realtime, :janitor_schedule_randomize)
    region = Application.get_env(:realtime, :region)

    state = %__MODULE__{
      timer: timer,
      region: region,
      chunks: chunks,
      start_after: start_after,
      randomize: randomize
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @impl true
  def init(%__MODULE__{start_after: start_after} = state) do
    timer = timer(state) + start_after
    Process.send_after(self(), :delete_old_messages, timer)
    Logger.info("Janitor started")
    {:ok, state}
  end

  @impl true
  def handle_info(:delete_old_messages, state) do
    Logger.info("Janitor started")
    %{region: region, chunks: chunks, tasks: tasks} = state
    regions = Nodes.region_to_tenant_regions(region)
    region_nodes = Nodes.region_nodes(region)

    query =
      from(t in Tenant,
        join: e in assoc(t, :extensions),
        where: t.notify_private_alpha == true,
        preload: :extensions
      )

    new_tasks =
      query
      |> where_region(regions)
      |> Repo.all()
      |> Stream.filter(&node_responsible_for_cleanup?(&1, region_nodes))
      |> Stream.chunk_every(chunks)
      |> Enum.map(fn chunks ->
        task =
          Task.Supervisor.async_nolink(
            __MODULE__.TaskSupervisor,
            fn -> run_cleanup_on_tenants(chunks) end,
            ordered: false
          )

        {task.ref, Enum.map(chunks, & &1.external_id)}
      end)
      |> Map.new()

    Process.send_after(self(), :delete_old_messages, timer(state))

    {:noreply, %{state | tasks: Map.merge(tasks, new_tasks)}}
  end

  def handle_info({:DOWN, ref, _, _, :normal}, state) do
    %{tasks: tasks} = state
    {_, tasks} = Map.pop(tasks, ref)
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:DOWN, ref, _, _, :killed}, state) do
    %{tasks: tasks} = state
    {tenants, tasks} = Map.pop(tasks, ref)

    log_error(
      "JanitorFailedToDeleteOldMessages",
      "Scheduled cleanup failed for tenants: #{inspect(tenants)}"
    )

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp where_region(query, nil), do: query

  defp where_region(query, regions) do
    where(query, [t, e], fragment("? -> 'region' in (?)", e.settings, splice(^regions)))
  end

  defp timer(%{timer: timer, randomize: true}), do: timer + :timer.minutes(Enum.random(1..59))
  defp timer(%{timer: timer}), do: timer

  defp node_responsible_for_cleanup?(%Tenant{external_id: external_id}, region_nodes) do
    case Node.self() do
      :nonode@nohost ->
        true

      _ ->
        index = :erlang.phash2(external_id, length(region_nodes))
        Enum.at(region_nodes, index) == Node.self()
    end
  end

  defp run_cleanup_on_tenants(tenants), do: Enum.map(tenants, &run_cleanup_on_tenant/1)

  defp run_cleanup_on_tenant(tenant) do
    Logger.metadata(project: tenant.external_id, external_id: tenant.external_id)
    Logger.info("Janitor cleaned realtime.messages")

    with {:ok, conn} <- Database.connect(tenant, "realtime_janitor", 1),
         :ok <- Messages.delete_old_messages(conn) do
      Logger.info("Janitor finished")
      :ok
    end
  end
end
