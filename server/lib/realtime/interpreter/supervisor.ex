defmodule Realtime.Interpreter.Supervisor do
  use DynamicSupervisor

  alias Realtime.Interpreter.{Transient, Persistent}

  def start_transient(workflow, ctx, args, opts) do
    DynamicSupervisor.start_child(__MODULE__, {Transient, {workflow, ctx, args, opts}})
  end

  def start_persistent(workflow, execution_id, ctx, args) do
    IO.puts "Start persistent"
    DynamicSupervisor.start_child(__MODULE__, {Persistent, {workflow, execution_id, {:start, ctx, args}}})
  end

  def recover_persistent(workflow, execution_id) do
    DynamicSupervisor.start_child(__MODULE__, {Persistent, {workflow, execution_id, :recover}})
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
