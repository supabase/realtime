defmodule Realtime.RateCounter.DynamicSupervisor do
  use DynamicSupervisor

  @spec start_link(list()) :: {:error, any} | {:ok, pid}
  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
