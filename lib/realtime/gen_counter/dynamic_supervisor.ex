defmodule Realtime.GenCounter.DynamicSupervisor do
  @moduledoc """
  DynamicSupervisor to spin up `GenCounter`s.
  """

  use DynamicSupervisor

  @spec start_link(list()) :: Supervisor.on_start()
  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
