defmodule Realtime.Workflows do
  @moduledoc """
  The Workflows context.

  Workflows are computations that are triggered by realtime events on postgres tables.

  Since computations can run for days or weeks, the workflow definition must be immutable. We achieve this by
  introducing workflows revisions: every time the user updates a workflow definition, the library creates a new
  revision of the workflow. Already running workflows will continue using the older revision of the workflow, while
  new executions will use the new revision.

  This module provides functions to manage Workflows, Revisions, Executions, and Events.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Realtime.Repo
  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.Interpreter
  alias Realtime.Workflows.{Execution, Event, Manager, Revision, Workflow}

  ## Workflow

  @doc """
  Returns the list of workflows.
  """
  def list_workflows do
    revisions = latest_revision_query()

    Repo.all(
      from(w in Workflow,
        preload: [
          revisions: ^revisions
        ]
      )
    )
  end

  @doc """
  Returns the workflow with the given id.
  """
  def get_workflow(id) do
    Repo.get(Workflow, id)
    |> Repo.preload(revisions: latest_revision_query())
    |> value_or_not_found(id)
  end

  @doc """
  Creates a workflow with its definition.
  """
  def create_workflow(attrs \\ %{}) do
    Multi.new()
    |> Multi.insert(:workflow, Workflow.create_changeset(%Workflow{}, attrs))
    |> Multi.insert(
      :revision,
      fn %{workflow: workflow} ->
        Revision.create_changeset(%Revision{}, workflow, 0, attrs)
      end
    )
    |> Repo.transaction()
    |> multi_error_to_changeset_error
  end

  @doc """
  Updates a workflow, adding a new revision if the definition changes.
  """
  def update_workflow(workflow, attrs \\ %{}) do
    with {:ok, revision} <- get_latest_workflow_revision(workflow.id) do
      multi =
        Multi.new()
        |> Multi.update(:workflow, Workflow.update_changeset(workflow, attrs))

      new_definition = Map.get(attrs, :definition)

      multi =
        if new_definition == nil or Map.equal?(new_definition, revision.definition) do
          multi
          |> Multi.put(:revision, revision)
        else
          multi
          |> Multi.insert(
            :revision,
            fn %{workflow: workflow} ->
              Revision.create_changeset(%Revision{}, workflow, revision.version + 1, attrs)
            end
          )
        end

      Repo.transaction(multi)
      |> multi_error_to_changeset_error
    end
  end

  @doc """
  Deletes the given workflow.
  """
  def delete_workflow(workflow) do
    Repo.delete(workflow)
  end

  ## Execution

  @doc """
  Creates a new workflow execution, using the most recent workflow revision.
  """
  def create_workflow_execution(workflow_id, attrs \\ %{}) do
    with {:ok, revision} <- get_latest_workflow_revision(workflow_id),
         {:ok, execution} <- insert_execution_with_revision(revision, attrs) do
      {:ok, %{execution: execution, revision: revision}}
    end
  end

  @doc """
  Returns the workflow execution with the given id.
  """
  def get_workflow_execution(id) do
    Execution
    |> Repo.get(id)
    |> Repo.preload([:revision])
    |> value_or_not_found(id)
  end

  @doc """
  Returns a list of executions for the given workflow.
  """
  def list_workflow_executions(workflow_id) do
    from(rev in Revision, where: [workflow_id: ^workflow_id], preload: :executions)
    |> Repo.all()
    |> Enum.flat_map(fn rev ->
      # Return a list of %{execution, revision} maps like other functions so it's convenient to render
      Enum.map(rev.executions, fn exec -> %{execution: exec, revision: rev} end)
    end)
  end

  @doc """
  Deletes the given workflow execution.
  """
  def delete_workflow_execution(execution) do
    Repo.delete(execution)
  end

  @doc """
  Creates a new workflow execution and waits for the workflow to finish.

  ## Options

  * `:timeout` - How long to wait for the workflow to finish.
  """
  def invoke_workflow_and_wait_for_reply(workflow, attrs, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)

    with {:ok, %{execution: execution, revision: revision}} <-
           create_workflow_execution(workflow.id, attrs) do
      # Start and await a Task so the original self() can wait for other messages.
      # In practice this is needed to test the ExecutionController.
      task =
        Task.async(fn ->
          with {:ok, _pid} <-
                 Interpreter.start_transient(workflow, execution, revision, reply_to: self()) do
            receive do
              {:succeed, msg} -> {:ok, msg, execution, revision}
              {:fail, msg} -> {:error, msg, execution, revision}
              err -> {:error, err, execution, revision}
            after
              timeout -> {:timeout, execution, revision}
            end
          end
        end)

      Task.await(task, timeout)
    end
  end


  @doc """
  Create and start the execution of all workflows that are triggered by `txn`.
  """
  def invoke_transaction_workflows(%Transaction{changes: [_ | _]} = txn) do
    workflows = Manager.workflows_for_change(txn)

    txn_as_map = Map.from_struct(txn)

    attrs = %{
      arguments: txn_as_map,
    }

    Enum.each(workflows, fn workflow ->
      with {:ok, %{execution: execution, revision: revision}} <- create_workflow_execution(workflow.id, attrs) do
	# TODO: should be based on default execution type
	{:ok, _pid} = Interpreter.start_persistent(workflow, execution, revision)
      end
    end)
    :ok
  end

  def invoke_transaction_workflows(txn) do
    :ok
  end

  ## Private

  defp get_latest_workflow_revision(workflow_id) do
    query =
      from(r in Revision,
        where: r.workflow_id == ^workflow_id,
        order_by: [
          desc: :version
        ],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  defp latest_revision_query do
    from(r in Revision,
      order_by: [
        desc: :version
      ],
      limit: 1
    )
  end

  defp insert_execution_with_revision(revision, attrs) do
    %Execution{}
    |> Execution.create_changeset(revision, attrs)
    |> Repo.insert()
  end

  defp value_or_not_found(nil, id), do: {:not_found, id}
  defp value_or_not_found(value, _id), do: {:ok, value}

  defp multi_error_to_changeset_error({:error, _, changeset, _}), do: {:error, changeset}
  defp multi_error_to_changeset_error(value), do: value
end
