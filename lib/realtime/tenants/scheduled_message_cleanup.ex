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
          start_after: pos_integer() | nil
        }

  defstruct timer: nil, region: nil, chunks: nil, start_after: nil

  def start_link(_args) do
    timer =
      Application.get_env(
        :realtime,
        :schedule_clean,
        :timer.hours(4)
      )

    start_after = Application.get_env(:realtime, :scheduled_start_after, 0)
    region = Application.get_env(:realtime, :region)
    chunks = Application.get_env(:realtime, :chunks, 10)
    state = %__MODULE__{timer: timer, region: region, chunks: chunks, start_after: start_after}
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
    %{region: region, chunks: chunks} = state
    regions = Nodes.region_to_tenant_regions(region)
    region_nodes = Nodes.region_nodes(region)

    Realtime.Repo.transaction(fn ->
      base = from(t in Tenant, select: t)

      query =
        if regions != nil,
          do:
            base
            |> join(:inner, [t], e in assoc(t, :extensions))
            |> where([t, e], fragment("? -> 'region' in (?)", e.settings, splice(^regions))),
          else: base

      query
      |> Repo.stream()
      |> Stream.filter(&node_responsible_for_cleanup?(&1, region_nodes))
      |> Stream.chunk_every(chunks)
      |> Enum.each(&run_cleanup_on_tenants/1)
    end)

    Process.send_after(self(), :delete_old_messages, timer(state))
    {:noreply, state}
  end

  defp timer(%{timer: timer}), do: timer + :timer.minutes(Enum.random(1..59))

  defp node_responsible_for_cleanup?(%Tenant{external_id: external_id}, region_nodes) do
    case Node.self() do
      :nonode@nohost ->
        true

      _ ->
        index = :erlang.phash2(external_id, length(region_nodes))
        Enum.at(region_nodes, index) == Node.self()
    end
  end

  defp run_cleanup_on_tenants(tenants) do
    Task.start(fn ->
      Repo.transaction(fn ->
        Enum.each(tenants, &run_cleanup_on_tenant/1)
      end)
    end)
  end

  defp run_cleanup_on_tenant(tenant) do
    Logger.metadata(project: tenant.external_id, external_id: tenant.external_id)
    tenant = Repo.preload(tenant, :extensions)
    Logger.info("ScheduledMessageCleanup cleaned realtime.messages")

    with {:ok, conn} <-
           Database.connect(tenant, "realtime_clean_messages", 1),
         {:ok, _} <- Messages.delete_old_messages(conn) do
      :ok
    else
      e ->
        log_error("FailedToDeleteOldMessages", e)
    end
  end
end
