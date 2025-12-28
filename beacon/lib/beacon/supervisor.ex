defmodule Beacon.Supervisor do
  @moduledoc false
  use Supervisor

  def name(scope), do: :"#{scope}_beacon"
  def supervisor_name(scope), do: :"#{scope}_beacon_supervisor"
  def partition_name(scope, partition), do: :"#{scope}_beacon_partition_#{partition}"
  def partition_entries_table(partition_name), do: :"#{partition_name}_entries"

  @spec partition(atom, Scope.group()) :: atom
  def partition(scope, group) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Beacon for scope #{inspect(scope)} is not started"
      partition_names -> elem(partition_names, :erlang.phash2(group, tuple_size(partition_names)))
    end
  end

  @spec partitions(atom) :: [atom]
  def partitions(scope) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Beacon for scope #{inspect(scope)} is not started"
      partition_names -> Tuple.to_list(partition_names)
    end
  end

  @spec start_link(atom, pos_integer(), Keyword.t()) :: Supervisor.on_start()
  def start_link(scope, partitions, opts \\ []) do
    args = [scope, partitions, opts]
    Supervisor.start_link(__MODULE__, args, name: supervisor_name(scope))
  end

  @impl true
  def init([scope, partitions, opts]) do
    children =
      for i <- 0..(partitions - 1) do
        partition_name = partition_name(scope, i)
        partition_entries_table = partition_entries_table(partition_name)

        ^partition_entries_table =
          :ets.new(partition_entries_table, [:set, :public, :named_table, read_concurrency: true])

        ^partition_name =
          :ets.new(partition_name, [:set, :public, :named_table, read_concurrency: true])

        %{
          id: i,
          start: {Beacon.Partition, :start_link, [scope, partition_name, partition_entries_table]}
        }
      end

    partition_names = for i <- 0..(partitions - 1), do: partition_name(scope, i)

    :persistent_term.put(scope, List.to_tuple(partition_names))

    children = [
      %{id: :scope, start: {Beacon.Scope, :start_link, [scope, opts]}} | children
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
