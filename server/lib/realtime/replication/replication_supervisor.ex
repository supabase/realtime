defmodule Realtime.ReplicationSupervisor do
  use Supervisor

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """

  Setting max_seconds to 1 and max_restarts to 1_000 prevents a database
  connection error from shutting down the app. This works in conjuction with
  DatabaseRetryMonitor.

    * If you wish to change these options, you must update @initial_delay
      and @maximum_delay in DatabaseRetryMonitor appropriately.

  """
  @impl true
  def init(config) do
    Supervisor.init(
      [{Realtime.Replication, config}],
      strategy: :one_for_one,
      max_seconds: 1,
      max_restarts: 1_000
    )
  end
end
