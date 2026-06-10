defmodule Forum.Supervisor do
  @moduledoc false
  use Supervisor

  def name(scope), do: :"#{scope}_forum"
  def supervisor_name(scope), do: :"#{scope}_forum_supervisor"
  def partition_name(scope, partition), do: :"#{scope}_forum_partition_#{partition}"
  def partition_entries_table(partition_name), do: :"#{partition_name}_entries"

  @spec partition(atom, Forum.group()) :: atom
  def partition(scope, group) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Forum for scope #{inspect(scope)} is not started"
      partition_names -> elem(partition_names, :erlang.phash2(group, tuple_size(partition_names)))
    end
  end

  @spec partitions(atom) :: [atom]
  def partitions(scope) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Forum for scope #{inspect(scope)} is not started"
      partition_names -> Tuple.to_list(partition_names)
    end
  end

  @spec start_link(module, atom, pos_integer(), Keyword.t()) :: Supervisor.on_start()
  def start_link(module, scope, partitions, opts \\ []) do
    args = [module, scope, partitions, opts]
    Supervisor.start_link(__MODULE__, args, name: supervisor_name(scope))
  end

  @impl true
  def init([module, scope, partitions, opts]) do
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
          start: {Forum.Partition, :start_link, [scope, partition_name, partition_entries_table]}
        }
      end

    partition_names = for i <- 0..(partitions - 1), do: partition_name(scope, i)

    :persistent_term.put(scope, List.to_tuple(partition_names))

    children = [
      %{id: :scope, start: {module, :start_link, [scope, opts]}} | children
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
