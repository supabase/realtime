defmodule Realtime.Tenants.ScheduledMessageCleanup do
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
          task_timeout: pos_integer() | nil
        }

  defstruct timer: nil,
            region: nil,
            chunks: nil,
            start_after: nil,
            randomize: nil,
            task_timeout: nil

  def start_link(_args) do
    timer = Application.get_env(:realtime, :schedule_clean, :timer.hours(4))
    start_after = Application.get_env(:realtime, :scheduled_start_after, 0)
    region = Application.get_env(:realtime, :region)
    chunks = Application.get_env(:realtime, :chunks, 10)
    randomize = Application.get_env(:realtime, :scheduled_randomize, true)
    task_timeout = Application.get_env(:realtime, :scheduled_cleanup_task_timeout)

    state = %__MODULE__{
      timer: timer,
      region: region,
      chunks: chunks,
      start_after: start_after,
      randomize: randomize,
      task_timeout: task_timeout
    }

    GenServer.start_link(__MODULE__, state, name: __MODULE__)
  end

  @impl true
  def init(%__MODULE__{start_after: start_after} = state) do
    timer = timer(state) + start_after
    Process.send_after(self(), :delete_old_messages, timer)
    Logger.info("ScheduledMessageCleanup started")
    {:ok, state}
  end

  @impl true
  def handle_info(:delete_old_messages, state) do
    Logger.info("ScheduledMessageCleanup started")
    %{region: region, chunks: chunks, task_timeout: task_timeout} = state
    regions = Nodes.region_to_tenant_regions(region)
    region_nodes = Nodes.region_nodes(region)

    Realtime.Repo.transaction(fn ->
      from(t in Tenant,
        join: e in assoc(t, :extensions),
        preload: :extensions,
        where: t.notify_private_alpha == true
      )
      |> where_region(regions)
      |> Repo.all()
      |> Stream.filter(&node_responsible_for_cleanup?(&1, region_nodes))
      |> Stream.chunk_every(chunks)
      |> Enum.map(fn chunks ->
        Task.Supervisor.async(
          __MODULE__.TaskSupervisor,
          fn -> run_cleanup_on_tenants(chunks) end
        )
      end)
      |> Task.await_many(task_timeout)
    end)

    Process.send_after(self(), :delete_old_messages, timer(state))
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
    Logger.info("ScheduledMessageCleanup cleaned realtime.messages")

    with {:ok, conn} <- Database.connect(tenant, "realtime_janitor", 1),
         {:ok, _} <- Messages.delete_old_messages(conn) do
      :ok
    else
      e -> log_error("FailedToDeleteOldMessages", e)
    end
  end
end
