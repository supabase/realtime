defmodule Forum.Supervisor do
  @moduledoc false
  use Supervisor

  def name(scope), do: :"#{scope}_forum"
  def supervisor_name(scope), do: :"#{scope}_forum_supervisor"
  def partition_name(scope, partition), do: :"#{scope}_forum_partition_#{partition}"
  def partition_entries_table(partition_name), do: :"#{partition_name}_entries"

  # Forum.Muster claim shard (one per partition index; same phash2 slice).
  def shard_name(scope, index), do: :"#{scope}_muster_shard_#{index}"

  # Per-shard durable claim-state ETS table. Created and owned by this Supervisor
  # (not the shard) so the shard's group_states survive a shard crash and are
  # rebuilt + reconciled on restart. One per shard index, same phash2 slice.
  def shard_states_table(scope, index), do: :"#{scope}_muster_shard_#{index}_states"

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

  # The Forum.Muster claim shard owning `group` — same phash2 slice as the
  # group's partition, so shard i aligns 1:1 with partition i.
  @spec shard(atom, Forum.group()) :: atom
  def shard(scope, group) do
    case :persistent_term.get({scope, :muster_shards}, :unknown) do
      :unknown -> raise "Forum.Muster shards for scope #{inspect(scope)} are not started"
      shard_names -> elem(shard_names, :erlang.phash2(group, tuple_size(shard_names)))
    end
  end

  @spec shards(atom) :: [atom]
  def shards(scope) do
    case :persistent_term.get({scope, :muster_shards}, :unknown) do
      :unknown -> raise "Forum.Muster shards for scope #{inspect(scope)} are not started"
      shard_names -> Tuple.to_list(shard_names)
    end
  end

  @spec start_link(module, atom, pos_integer(), Keyword.t()) :: Supervisor.on_start()
  def start_link(module, scope, partitions, opts \\ []) do
    args = [module, scope, partitions, opts]
    Supervisor.start_link(__MODULE__, args, name: supervisor_name(scope))
  end

  @impl true
  def init([module, scope, partitions, opts]) do
    partition_children =
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

    scope_child = %{id: :scope, start: {module, :start_link, [scope, opts]}}

    children = scope_children(module, scope, partitions, opts, scope_child, partition_children)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Forum.Muster adds, per scope: a shared ring (a supervised sibling, so a
  # coordinator restart does not take it down under the shards that read it), the
  # router-role occupancy table, and N claim shards (one per partition index).
  # The occupancy table and the per-shard durable claim-state tables are created
  # HERE (owned by this long-lived Supervisor) rather than inside the coordinator
  # or shard processes, so they survive a coordinator/shard restart — the shards
  # write the occupancy table directly and rebuild their group_states from the
  # state tables. The ring starts BEFORE the coordinator (which resets its node
  # set at init); shards start after the partitions whose ETS tables they rebuild
  # from. Forum.Census gets none of these.
  defp scope_children(
         Forum.Muster.Scope,
         scope,
         partitions,
         opts,
         scope_child,
         partition_children
       ) do
    # :public so the coordinator, the local shards, and the :erpc workers running
    # the remote entry points (occupied/4, vacant_batch/4) all write it directly,
    # bypassing the coordinator mailbox; write_concurrency makes that scale.
    occupancy_table = Forum.Muster.Scope.occupancy_table_name(scope)

    ^occupancy_table =
      :ets.new(occupancy_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    shard_names = for i <- 0..(partitions - 1), do: shard_name(scope, i)
    :persistent_term.put({scope, :muster_shards}, List.to_tuple(shard_names))

    shard_children =
      for i <- 0..(partitions - 1) do
        # :public (Supervisor owns it, the shard writes it). Single writer (the
        # shard) so no write_concurrency needed.
        states_table = shard_states_table(scope, i)

        ^states_table =
          :ets.new(states_table, [:set, :public, :named_table, read_concurrency: true])

        %{id: {:muster_shard, i}, start: {Forum.Muster.Shard, :start_link, [scope, i, opts]}}
      end

    [Forum.Muster.Scope.ring_child_spec(scope), scope_child] ++
      partition_children ++ shard_children
  end

  defp scope_children(_module, _scope, _partitions, _opts, scope_child, partition_children) do
    [scope_child | partition_children]
  end
end
