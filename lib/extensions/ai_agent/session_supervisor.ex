defmodule Extensions.AiAgent.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor that manages AI agent sessions.
  One session per channel join with AI enabled.
  """

  use DynamicSupervisor

  alias Extensions.AiAgent.Session

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Session, opts})
  end
end
