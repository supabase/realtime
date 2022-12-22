defmodule Extensions.PostgresCdcStream.Supervisor do
  @moduledoc """
  Supervisor to spin up the Postgres CDC Stream tree.
  """
  use Supervisor

  alias Extensions.PostgresCdcStream, as: Stream

  @spec start_link :: :ignore | {:error, any} | {:ok, pid}
  def start_link() do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    :syn.add_node_to_scopes([PostgresCdcStream])

    children = [
      {
        PartitionSupervisor,
        partitions: 20,
        child_spec: DynamicSupervisor,
        strategy: :one_for_one,
        name: Stream.DynamicSupervisor
      },
      Stream.Tracker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
