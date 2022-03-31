defmodule Extensions.Postgres.Supervisor do
  use Supervisor

  alias Extensions.Postgres

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :syn.set_event_handler(Extensions.Postgres.SynHandler)

    :syn.add_node_to_scopes([
      Postgres.Subscribers,
      Postgres.RegionNodes
    ])

    :syn.join(Postgres.RegionNodes, System.get_env("FLY_REGION"), self(), node: node())

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Extensions.Postgres.DynamicSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
