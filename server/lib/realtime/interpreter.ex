defmodule Realtime.Interpreter do
  @moduledoc """
  Workflows interpreter. Start transient and persistent workflows.
  """

  alias Realtime.Interpreter.{Context, PersistentManager, Supervisor}

  @doc """
  Starts a transient workflow.

  ## Options

   * `:reply_to` - If set, send a message with the execution result to this PID.
  """
  def start_transient(workflow, execution, revision, opts \\ []) do
    with {:ok, asl_workflow} <- Workflows.parse(revision.definition) do
      ctx = Context.create(workflow, execution, revision)
      Supervisor.start_transient(asl_workflow, ctx, execution.arguments, opts)
    end
  end

  @doc """
  Starts a new persistent workflow.

  This function returns an error if the specific execution was already started.
  Use `resume_persistent` to resume the execution of a persistent workflow.
  """
  def start_persistent(workflow, execution, revision) do
    with {:ok, asl_workflow} <- Workflows.parse(revision.definition) do
      ctx = Context.create(workflow, execution, revision)
      PersistentManager.start_persistent(asl_workflow, execution.id, ctx, execution.arguments)
    end
  end

  @doc """
  Resumes the execution with the given `execution_id`, starting from the activity
  waiting for  `command`.
  """
  def resume_persistent(execution_id, command) do
    PersistentManager.resume_persistent(execution_id, command)
  end
end
