defmodule Realtime.Workflows.Manager do
  @moduledoc """
  This GenServer keeps a list of all available workflows.

  This server is used to get a list of all workflows that should be triggered in
  response to a realtime event.
  """
  use GenServer

  require Logger

  alias Realtime.Adapters.Changes.{NewRecord, UpdatedRecord, DeletedRecord, Transaction}
  alias Realtime.TransactionFilter
  alias Realtime.Workflows
  alias Realtime.Workflows.{Execution, Revision, Workflow}

  @table_name :workflows_manager

  ## Manager API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Send notification for txn to the workflow manager.
  """
  def notify(%Transaction{changes: [_ | _]} = txn) do
    GenServer.call(__MODULE__, {:notify, txn})
  end

  def notify(txn) do
    :ok
  end

  @doc """
  Return a list of workflows that can be triggered by change.
  """
  def workflows_for_change(txn) do
    strict = [
      Execution.transaction_filter(),
      Revision.transaction_filter(),
      Workflow.transaction_filter(),
    ]
    # No need to call GenServer, we can lookup the table directly
    :ets.foldl(
      fn ({_, workflow}, acc) ->
        event = %{event: "*", relation: workflow.trigger}
        if TransactionFilter.matches?(event, txn, strict: strict) do
          [workflow | acc]
        else
          acc
        end
      end,
      [],
      @table_name
    )
  end

  @doc """
  Return the workflow with the given id, or nil if not found.
  """
  def workflow_by_id(id) do
    case :ets.lookup(@table_name, id) do
      [{_, workflow}] -> workflow
      [] -> nil
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(config) do
    workflows = :ets.new(@table_name, [:named_table, :protected])

    {:ok, nil, {:continue, :load_workflows}}
  end

  @impl true
  def handle_continue(:load_workflows, state) do
    Workflows.list_workflows()
    |> Enum.each(fn workflow -> do_insert_workflow(@table_name, workflow) end)
    {:noreply, state}
  end

  @impl true
  def handle_call({:notify, txn}, _from, state) do
    do_handle_notification(@table_name, txn)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private

  defp do_handle_notification(table, txn) do
    for change <- txn.changes do
      case change_type(change) do
        :insert -> insert_workflow(table, change)
        :update -> update_workflow(table, change)
        :delete -> delete_workflow(table, change)
        _ -> nil
      end
    end
  end

  defp insert_workflow(table, %NewRecord{record: record} = change) do
    case Workflows.get_workflow(record["id"]) do
      {:ok, workflow} -> do_insert_workflow(table, workflow)
      {:not_found, _} ->
        Logger.error("Received notification of workflow INSERT, but workflow does not exist. #{inspect change}")
    end
  end

  defp update_workflow(table, %UpdatedRecord{record: record} = change) do
    case Workflows.get_workflow(record["id"]) do
      {:ok, workflow} -> do_insert_workflow(table, workflow)
      {:not_found, _} ->
        Logger.error("Received notification of workflow UPDATE, but workflow does not exist. #{inspect change}")
    end
  end

  defp delete_workflow(table, %DeletedRecord{old_record: record} = _change) do
    :ets.delete(table, record["id"])
  end

  defp do_insert_workflow(table, workflow) do
    :ets.insert(table, {workflow.id, workflow})
  end

  defp change_type(change) do
    if change.schema == Workflow.table_schema() and change.table == Workflow.table_name() do
      case change.type do
        "INSERT" -> :insert
        "UPDATE" -> :update
        "DELETE" -> :delete
        _ -> :other
      end
    else
        :other
    end
  end
end
