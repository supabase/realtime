defmodule Extensions.PostgresCdcRls.Supervisor do
  @moduledoc """
  Supervisor to spin up the Postgres CDC RLS tree.
  """
  use Supervisor

  alias Extensions.PostgresCdcRls, as: Rls

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :syn.set_event_handler(Rls.SynHandler)
    :syn.add_node_to_scopes([Rls])

    children = [
      {
        PartitionSupervisor,
        partitions: 20,
        child_spec: DynamicSupervisor,
        strategy: :one_for_one,
        name: Rls.DynamicSupervisor
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
