defmodule Extensions.AiAgent.Supervisor do
  @moduledoc """
  Top-level supervisor for the AI Agent extension.
  Starts the shared Finch HTTP pool, task supervisor, and session DynamicSupervisor.

  max_restarts is set high so transient Finch pool crashes (e.g. abrupt connection
  closures during tests or sudden provider outages) do not cascade and kill the
  SessionSupervisor.
  """

  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    finch_config = Application.get_env(:realtime, AiAgent.Finch, [])
    finch_pools = Keyword.get(finch_config, :pools, %{})

    children = [
      {Finch, name: AiAgent.Finch, pools: finch_pools},
      {Task.Supervisor, name: Extensions.AiAgent.TaskSupervisor},
      Extensions.AiAgent.SessionSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 100, max_seconds: 60)
  end
end
