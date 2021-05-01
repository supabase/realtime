defmodule Realtime.Interpreter.PersistentManager do
  @moduledoc """
  This GenServer manages persistent workflow executions.

  Workflow executions can last days or weeks and for this reason we need a process to
  store their state to persistent storage (by storing their events to postgres),
  and a way to restore their state when they receive an external event (either a Wait
  or Task finishing).

  This server keeps a cache of the most recently used interpreters/executions, if the
  server receives an event for an execution not in cache, it restores its state from
  the persistent storage.
  """
  use GenServer

  require Logger

  alias Realtime.Interpreter.Supervisor


  defmodule State do
    defstruct [:executions]
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def start_persistent(workflow, execution_id, ctx, args) do
    GenServer.call(__MODULE__, {:start_execution, workflow, execution_id, ctx, args})
  end

  def resume_persistent(execution_id, command) do
    GenServer.call(__MODULE__, {:resume_execution, execution_id, command})
  end

  ## Callbacks

  @impl true
  def init(_config) do
    # Start with an empty cache
    state = %State{
      executions: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_execution, workflow, execution_id, ctx, args}, _from, state) do
    IO.puts "PM: Start execution"
    {:ok, pid} = Supervisor.start_persistent(workflow, execution_id, ctx, args)
    new_executions = Map.put(state.executions, ctx.execution_id, pid)
    new_state = %State{state | executions: new_executions}
    {:reply, {:ok, pid}, new_state}
  end

  @impl true
  def handle_call({:resume_execution, execution_id, command}, _from, state) do
    Logger.info("Resume execution #{inspect execution_id} #{inspect command}")
    # TODO: how to handle error?
    {:ok, new_state} = do_resume_execution(execution_id, command, state)
    {:reply, :ok, new_state}
  end

  ## Private

  defp do_resume_execution(execution_id, command, state) do
    {:ok, pid} = get_or_recover_execution(execution_id, state)
    GenServer.cast(pid, {:resume_execution, command})
    {:ok, state}
  end

  defp get_or_recover_execution(execution_id, state) do
    case Map.fetch(state.executions, execution_id) do
      {:ok, pid} -> {:ok, pid}
      :error ->
	{:ok, execution} = Realtime.Workflows.get_workflow_execution(execution_id)
	with {:ok, asl_workflow} <- Workflows.parse(execution.revision.definition) do
	  Supervisor.recover_persistent(asl_workflow, execution_id)
	end
    end
  end
end
