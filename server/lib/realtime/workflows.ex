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
  alias Realtime.Workflows.Execution
  alias Realtime.Workflows.Event
  alias Realtime.Workflows.Revision
  alias Realtime.Workflows.Workflow

  @doc """
  Returns the list of workflows.
  """
  def list_workflows do
    revisions = latest_revision_query()
    Repo.all from w in Workflow, preload: [
      revisions: ^revisions
    ]
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

  @doc """
  Creates a new workflow execution, using the most recent workflow revision.
  """
  def create_workflow_execution(workflow_id, attrs \\ %{}) do
    with {:ok, revision} <- get_latest_workflow_revision(workflow_id),
         {:ok, execution} <- insert_execution_with_revision(revision, attrs) do
      {:ok, %{execution: execution, revision: revision}}
    end
  end

  ## Private

  defp get_latest_workflow_revision(workflow_id) do
    query = from r in Revision,
                 where: r.workflow_id == ^workflow_id,
                 order_by: [
                   desc: :version
                 ],
                 limit: 1
    case Repo.one(query) do
      nil -> {:error, :not_found}
      revision -> {:ok, revision}
    end
  end

  defp latest_revision_query do
    from r in Revision,
         order_by: [
           desc: :version
         ],
         limit: 1
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
