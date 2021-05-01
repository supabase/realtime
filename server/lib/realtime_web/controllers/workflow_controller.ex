defmodule RealtimeWeb.WorkflowController do
  use RealtimeWeb, :controller

  require Logger

  alias Realtime.Workflows

  action_fallback RealtimeWeb.ErrorController

  def index(conn, _params) do
    workflows = Workflows.list_workflows()
    with {:ok, workflows} <- workflows_with_revision(workflows, []) do
      render(conn, "index.json", workflows: workflows)
    end
  end

  def create(conn, params) do
    with {:ok, workflow} <- Workflows.create_workflow(params) do
      conn
      |> put_status(:created)
      |> render("show.json", workflow: workflow)
    end
  end

  def show(conn, %{"id" => workflow_id}) do
    with {:ok, workflow} <- Workflows.get_workflow(workflow_id),
         {:ok, workflow} <- workflow_with_revision(workflow) do
      conn
      |> put_status(:ok)
      |> render("show.json", workflow: workflow)
    end
  end

  def update(conn, %{"id" => workflow_id} = params) do
    with {:ok, workflow} <- Workflows.get_workflow(workflow_id),
         {:ok, updated_workflow} <- Workflows.update_workflow(workflow, params) do
      conn
      |> put_status(:ok)
      |> render("show.json", workflow: updated_workflow)
    end
  end

  def delete(conn, %{"id" => workflow_id}) do
    with {:ok, workflow} <- Workflows.get_workflow(workflow_id),
         {:ok, _} <- Workflows.delete_workflow(workflow),
         {:ok, workflow} <- workflow_with_revision(workflow) do
        conn
      |> put_status(:ok)
      |> render("show.json", workflow: workflow)
    end
  end

  ## Private

  defp workflows_with_revision([], acc) do
    {:ok, Enum.reverse(acc)}
  end

  defp workflows_with_revision([workflow | workflows], acc) do
    with {:ok, workflow} <- workflow_with_revision(workflow) do
      workflows_with_revision(workflows, [workflow | acc])
    end
  end

  defp workflow_with_revision(workflow) do
    case workflow.revisions do
      [revision | _] ->
        {:ok, %{workflow: workflow, revision: revision}}
      [] ->
        {:error, "missing revision"}
    end
  end
end
