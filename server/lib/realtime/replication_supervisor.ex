defmodule Realtime.ReplicationSupervisor do
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    children = [
      {
        Realtime.Replication,
        config
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
