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
    Repo.all from w in Workflow, preload: [
      revisions: ^latest_revision_query
    ]
  end

  @doc """
  Returns the workflow with the given id.
  """
  def get_workflow(id) do
    Repo.get(Workflow, id)
    |> Repo.preload(revisions: latest_revision_query())
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
  end

  @doc """
  Updates a workflow, adding a new revision if the definition changes.
  """
  def update_workflow(workflow, attrs \\ %{}) do
    case get_latest_workflow_revision(workflow.id) do
      nil -> {:error, :not_found}
      revision ->
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
    Repo.one(query)
  end

  defp latest_revision_query do
    from r in Revision,
         order_by: [
           desc: :version
         ],
         limit: 1
  end
end
