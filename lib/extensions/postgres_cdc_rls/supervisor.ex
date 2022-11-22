defmodule Extensions.PostgresCdcRls.Supervisor do
  use Supervisor

  alias Extensions.PostgresCdcRls, as: Rls

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :syn.add_node_to_scopes([Extensions.PostgresCdcRls])

    children = [
      {
        PartitionSupervisor,
        partitions: 20,
        child_spec: DynamicSupervisor,
        strategy: :one_for_one,
        name: Rls.DynamicSupervisor
      },
      Rls.SubscriptionManagerTracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
