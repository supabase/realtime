defmodule Realtime.Tenants.Janitor do
  @moduledoc """
  Scheduled tasks for the Tenants.
  """

  use GenServer
  require Logger

  import Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Tenants
  alias Realtime.Tenants.Migrations

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

  @table_name :"syn_registry_by_name_Elixir.Realtime.Tenants.Connect"
  @impl true
  def handle_info(:delete_old_messages, state) do
    Logger.info("Janitor started")
    %{chunks: chunks, tasks: tasks} = state

    matchspec = [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", Node.self()}, [], [:"$1"]}
    ]

    new_tasks =
      :ets.select(@table_name, matchspec)
      |> Stream.chunk_every(chunks)
      |> Stream.map(fn chunks ->
        task =
          Task.Supervisor.async_nolink(
            __MODULE__.TaskSupervisor,
            fn -> perform_mantaince_tasks(chunks) end,
            ordered: false
          )

        {task.ref, chunks}
      end)
      |> Map.new()

    Process.send_after(self(), :delete_old_messages, timer(state))

    {:noreply, %{state | tasks: Map.merge(tasks, new_tasks)}}
  end

  def handle_info({:DOWN, ref, _, _, :normal}, state) do
    %{tasks: tasks} = state
    {tenants, tasks} = Map.pop(tasks, ref)
    Logger.info("Janitor finished for tenants: #{inspect(tenants)}")
    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info({:DOWN, ref, _, _, :killed}, state) do
    %{tasks: tasks} = state
    tenants = Map.get(tasks, ref)

    log_error(
      "JanitorFailedToDeleteOldMessages",
      "Scheduled cleanup failed for tenants: #{inspect(tenants)}"
    )

    {:noreply, %{state | tasks: tasks}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp timer(%{timer: timer, randomize: true}), do: timer + :timer.minutes(Enum.random(1..59))
  defp timer(%{timer: timer}), do: timer

  defp perform_mantaince_tasks(tenants), do: Enum.map(tenants, &perform_mantaince_task/1)

  defp perform_mantaince_task(tenant_external_id) do
    Logger.metadata(project: tenant_external_id, external_id: tenant_external_id)
    Logger.info("Janitor starting realtime.messages cleanup")

    with %Tenant{} = tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_external_id),
         {:ok, conn} <- Database.connect(tenant, "realtime_janitor", 1),
         :ok <- Messages.delete_old_messages(conn),
         :ok <- Migrations.create_partitions(conn) do
      Logger.info("Janitor finished")

      GenServer.stop(conn)
      :ok
    end
  end
end
