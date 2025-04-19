defmodule Realtime.PubSubAdapter.CachexSupervisor do
  use Supervisor
  require Cachex.Spec

  @expiration :timer.seconds(10)

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {Cachex, name: Realtime.PubSubAdapter.Cachex, expiration: Cachex.Spec.expiration(default: @expiration)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
