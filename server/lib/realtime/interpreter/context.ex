defmodule Realtime.Interpreter.Context do
  @moduledoc """
  Context is the state shared across all states.
  """

  @derive Jason.Encoder
  defstruct [:workflow_name, :workflow_version, :execution_id]

  @doc """
  Creates a new Context.
  """
  def create(workflow, execution, revision) do
    %__MODULE__{
      workflow_name: workflow.name,
      workflow_version: revision.version,
      execution_id: execution.id
    }
  end
end
