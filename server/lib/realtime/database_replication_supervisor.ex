defmodule Realtime.DatabaseReplicationSupervisor do
  use Supervisor

  alias Realtime.Adapters.Postgres.EpgsqlServer
  alias Realtime.Replication
  alias Realtime.BacklogReplication

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    children = [
      Replication,
      BacklogReplication,
      {EpgsqlServer, config}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
