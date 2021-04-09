defmodule RealtimeWeb.ExecutionController do
  use RealtimeWeb, :controller
  alias Realtime.Workflows

  require Logger

  action_fallback RealtimeWeb.ErrorController

  def index(conn, %{"workflow_id" => workflow_id}) do
    executions = Workflows.list_workflow_executions(workflow_id)
    render(conn, "index.json", executions: executions)
  end

  def create(conn, %{"workflow_id" => workflow_id, "arguments" => arguments} = params) do
    log_type = Map.get(params, "log_type", nil)
    start_state = Map.get(params, "start_state", nil)

    attrs = %{
      arguments: arguments,
      start_state: start_state,
      log_type: log_type
    }

    with {:ok, workflow} <- Workflows.get_workflow(workflow_id) do
      case Workflows.invoke_workflow_and_wait_for_reply(workflow, attrs) do
        {:ok, response, execution, revision} ->
          conn
          |> put_status(:created)
          |> render("result.json", execution: execution, revision: revision, result: response)
        {:timeout, execution, revision} ->
          conn
          |> put_status(:bad_request)
          |> render("error.json", execution: execution, revision: revision, error: "timeout")
        {:error, err, execution, revision} ->
          # Error during execution
          Logger.warn("ExecutionController.create: fail #{inspect err}")
          conn
          |> put_status(:bad_request)
          |> render("error.json", execution: execution, revision: revision, error: "execution error")
        {:error, changeset} ->
          # Changeset error, delegate to error controller
          RealtimeWeb.ErrorController.call(conn, {:error, changeset})
      end
    end
  end

  def show(conn, %{"id" => execution_id}) do
    with {:ok, execution} <- Workflows.get_workflow_execution(execution_id) do
      conn
      |> put_status(:ok)
      |> render("show.json", execution: execution, revision: execution.revision, result: nil)
    end
  end

  def delete(conn, %{"id" => execution_id}) do
    with {:ok, execution} <- Workflows.get_workflow_execution(execution_id),
         {:ok, _} <- Workflows.delete_workflow_execution(execution) do
      conn
      |> put_status(:ok)
      |> render("show.json", execution: execution, revision: execution.revision)
    end
  end
end
