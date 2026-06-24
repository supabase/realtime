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

  # The Forum.Muster claim shard owning `group`: same phash2 slice as the
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
    # The per-slice membership tables, created and owned by this long-lived
    # Supervisor (NOT by the process that writes them) so they survive that
    # process's crash and are rebuilt on restart. The layout differs per
    # primitive (see create_membership_tables/3).
    for i <- 0..(partitions - 1), do: create_membership_tables(module, scope, i)

    partition_names = for i <- 0..(partitions - 1), do: partition_name(scope, i)

    :persistent_term.put(scope, List.to_tuple(partition_names))

    scope_child = %{id: :scope, start: {module, :start_link, [scope, opts]}}

    children = scope_children(module, scope, partitions, opts, scope_child)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Forum.Muster keeps NO counts table: its Forum.Muster.Shard derives "is there a
  # member" / "is the group now empty" / the member count from the entries table on
  # demand. The entries table is an :ordered_set so a group's members are
  # contiguous and those derivations are bounded prefix scans, not full-table scans.
  defp create_membership_tables(Forum.Muster.Scope, scope, i) do
    entries = partition_entries_table(partition_name(scope, i))
    ^entries = :ets.new(entries, [:ordered_set, :public, :named_table, read_concurrency: true])
    :ok
  end

  # Forum.Census's Forum.Partition keeps a denormalized O(1) counts table
  # (partition_name) alongside the entries table, rebuilt from entries on restart.
  defp create_membership_tables(_module, scope, i) do
    partition_name = partition_name(scope, i)
    entries = partition_entries_table(partition_name)

    ^entries = :ets.new(entries, [:set, :public, :named_table, read_concurrency: true])

    ^partition_name =
      :ets.new(partition_name, [:set, :public, :named_table, read_concurrency: true])

    :ok
  end

  # Forum.Muster adds, per scope: a shared ring (a supervised sibling, so a
  # coordinator restart does not take it down under the shards that read it), the
  # router-role occupancy table, and N claim shards (one per partition index). A
  # Muster shard absorbs the membership job Forum.Partition does for Census, so
  # Muster starts NO Forum.Partition processes: the shard owns the slice's
  # entries table (created in init/1, no counts table) along with its claim state.
  #
  # The occupancy table and the per-shard durable claim-state tables are created
  # HERE (owned by this long-lived Supervisor) rather than inside the coordinator
  # or shard processes, so they survive a coordinator/shard restart: the shards
  # write the occupancy table directly and rebuild their group_states from the
  # state tables. The ring starts BEFORE the coordinator (which resets its node
  # set at init). The shards rebuild from Supervisor-owned tables (created in
  # init/1, before any child starts), so they have no start-order dependency on a
  # membership process. Forum.Census gets none of these.
  defp scope_children(Forum.Muster.Scope, scope, partitions, opts, scope_child) do
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
        write_concurrency: :auto
      ])

    shard_names = for i <- 0..(partitions - 1), do: shard_name(scope, i)
    :persistent_term.put({scope, :muster_shards}, List.to_tuple(shard_names))

    shard_children =
      for i <- 0..(partitions - 1) do
        # :public (Supervisor owns it, the shard writes it).
        states_table = shard_states_table(scope, i)

        ^states_table =
          :ets.new(states_table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: :auto
          ])

        %{id: {:muster_shard, i}, start: {Forum.Muster.Shard, :start_link, [scope, i, opts]}}
      end

    [Forum.Muster.Scope.ring_child_spec(scope), scope_child] ++ shard_children
  end

  # Forum.Census: one Forum.Partition process per slice owns membership (entries +
  # counts tables, created in init/1). No shards, ring, or occupancy table.
  defp scope_children(_module, scope, partitions, _opts, scope_child) do
    partition_children =
      for i <- 0..(partitions - 1) do
        partition_name = partition_name(scope, i)

        %{
          id: i,
          start:
            {Forum.Partition, :start_link,
             [scope, partition_name, partition_entries_table(partition_name)]}
        }
      end

    [scope_child | partition_children]
  end
end
