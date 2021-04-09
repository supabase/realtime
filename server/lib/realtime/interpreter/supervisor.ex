defmodule Realtime.Interpreter.Supervisor do
  use DynamicSupervisor

  alias Realtime.Interpreter.Transient

  def start_transient(workflow, ctx, args) do
    DynamicSupervisor.start_child(__MODULE__, {Transient, {workflow, ctx, args}})
  end

  ## Callbacks

  def start_link(config) do
    DynamicSupervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(_config) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
