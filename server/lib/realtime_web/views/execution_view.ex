defmodule RealtimeWeb.ExecutionView do
  use RealtimeWeb, :view

  def render("index.json", %{executions: executions}) do
    %{
      executions: Enum.map(executions, fn %{execution: ex, revision: rev} -> render_execution(ex, rev) end)
    }
  end

  def render("show.json", %{execution: execution, revision: revision}) do
    %{
      execution: render_execution(execution, revision)
    }
  end

  def render("result.json", %{execution: execution, revision: revision, result: result}) do
    %{
      execution: render_execution(execution, revision),
      result: result,
    }
  end

  def render("error.json", %{execution: execution, revision: revision, error: error}) do
    %{
      execution: render_execution(execution, revision),
      error: error
    }
  end

  def render_execution(execution, revision) do
    %{
      id: execution.id,
      workflow_id: revision.workflow_id,
      arguments: execution.arguments,
      created_at: execution.inserted_at,
      updated_at: execution.updated_at
    }
  end
end
