defmodule Rollcall.Tracker.Local do
  @moduledoc """
  The set of entries that the processes on this node tracks in one tracker.

  `Local` is a pure data structure. Each function returns the new set. A
  function that changes the set also returns the `Rollcall.Tracker.Local.Changes`
  that the change made.

  The set has an index by entry id, by partition and by pid. The id of an entry
  is `{pid, partition, key}`. A pid has one entry for each partition and key.
  """

  @type partition :: String.t()
  @type key :: String.t()
  @type meta :: map()
  @type ref :: String.t() | reference()
  @type entry_id :: {pid(), partition(), key()}

  defmodule Entry do
    @moduledoc """
    An entry that a process tracks.

    The `ref` identifies the entry. The `key` and the `meta` are the payload.
    """

    defstruct [:partition, :pid, :key, :ref, :meta]

    @type t :: %__MODULE__{
            partition: Rollcall.Tracker.Local.partition(),
            pid: pid(),
            key: Rollcall.Tracker.Local.key(),
            ref: Rollcall.Tracker.Local.ref(),
            meta: Rollcall.Tracker.Local.meta()
          }

    @doc "Returns an entry."
    @spec new(
            pid(),
            Rollcall.Tracker.Local.partition(),
            Rollcall.Tracker.Local.key(),
            Rollcall.Tracker.Local.meta(),
            Rollcall.Tracker.Local.ref()
          ) :: t()
    def new(pid, partition, key, meta, ref) do
      %__MODULE__{
        pid: pid,
        partition: partition,
        key: key,
        meta: meta,
        ref: ref
      }
    end

    @doc "Returns the id of `entry`."
    @spec id(t()) :: Rollcall.Tracker.Local.entry_id()
    def id(entry) do
      id(entry.pid, entry.partition, entry.key)
    end

    @doc "Returns the id of the entry of `pid` for `key` in `partition`."
    @spec id(pid(), Rollcall.Tracker.Local.partition(), Rollcall.Tracker.Local.key()) ::
            Rollcall.Tracker.Local.entry_id()
    def id(pid, partition, key) do
      {pid, partition, key}
    end
  end

  defmodule Changes do
    @moduledoc """
    The entries that one change added and removed.

    `joins` holds the entries that the change added. `leaves` holds the entries
    that the change removed. A replace has one leave and one join.
    """

    defstruct joins: [], leaves: []

    @type t :: %__MODULE__{
            joins: [Entry.t()],
            leaves: [Entry.t()]
          }

    @doc "Returns changes with no join and no leave."
    @spec new() :: t()
    def new do
      %__MODULE__{}
    end

    @doc "Returns true if changes are empty"
    def empty?(%__MODULE__{joins: [], leaves: []}), do: true
    def empty?(_changes), do: false

    @doc "Adds `entry` to the joins."
    @spec join(t(), Entry.t()) :: t()
    def join(changes, entry) do
      %{changes | joins: [entry | changes.joins]}
    end

    @doc "Adds `entry` to the leaves."
    @spec leave(t(), Entry.t()) :: t()
    def leave(changes, entry) do
      %{changes | leaves: [entry | changes.leaves]}
    end
  end

  defstruct entries_by_id: %{}, partitions: %{}, pids: %{}

  @opaque t :: %__MODULE__{
            entries_by_id: %{entry_id() => Entry.t()},
            partitions: %{partition() => MapSet.t(entry_id())},
            pids: %{pid() => MapSet.t(entry_id())}
          }

  @doc "Returns an empty set."
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc "Returns true when the set holds no entry."
  @spec empty?(t()) :: boolean()
  def empty?(local) do
    map_size(local.entries_by_id) == 0
  end

  @doc """
  Returns the entries in `partition`. 

  The order is not defined.
  """
  @spec entries(t(), partition()) :: [Entry.t()]
  def entries(local, partition) do
    local.partitions
    |> Map.get(partition, MapSet.new())
    |> Enum.map(fn key -> Map.get(local.entries_by_id, key) end)
  end

  @doc """
  Adds an entry with `ref` for `pid`, `key` and `meta` in `partition`.

  When `pid` already has an entry for `key` in `partition`, the new entry
  replaces it. The old entry is a leave and the new entry is a join. The new
  entry has `ref` even when the meta is the same.
  """
  @spec track(t(), pid(), partition(), key(), meta(), ref()) :: {Changes.t(), t()}
  def track(local, pid, partition, key, meta, ref) do
    entry = Entry.new(pid, partition, key, meta, ref)

    {Changes.new(), local}
    |> remove_entry(Entry.id(entry))
    |> add_entry(entry)
  end

  @doc "Returns true when `pid` has at least one entry."
  @spec tracks?(t(), pid()) :: boolean()
  def tracks?(local, pid) do
    Map.has_key?(local.pids, pid)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition`.

  The removed entry is a leave. When no entry matches, the changes are empty
  and the set does not change.
  """
  @spec untrack(t(), pid(), partition(), key()) :: {Changes.t(), t()}
  def untrack(local, pid, partition, key) do
    remove_entry({Changes.new(), local}, Entry.id(pid, partition, key))
  end

  @doc """
  Removes all entries of `pid` in all partitions.

  Each removed entry is a leave. When `pid` has no entry, the changes are
  empty and the set does not change.
  """
  @spec untrack_pid(t(), pid()) :: {Changes.t(), t()}
  def untrack_pid(local, pid) do
    local.pids
    |> Map.get(pid, MapSet.new())
    |> Enum.reduce({Changes.new(), local}, fn entry_id, acc ->
      remove_entry(acc, entry_id)
    end)
  end

  defp add_entry({changes, local}, entry) do
    entry_id = Entry.id(entry)
    default_entry_id_set = MapSet.new([entry_id])

    partition_set =
      Map.update(local.partitions, entry.partition, default_entry_id_set, fn partition_set ->
        MapSet.put(partition_set, entry_id)
      end)

    pid_set =
      Map.update(local.pids, entry.pid, default_entry_id_set, fn pid_set ->
        MapSet.put(pid_set, entry_id)
      end)

    {
      Changes.join(changes, entry),
      %{
        local
        | entries_by_id: Map.put(local.entries_by_id, entry_id, entry),
          partitions: partition_set,
          pids: pid_set
      }
    }
  end

  defp remove_entry({changes, local}, {pid, partition, _key} = entry_id) do
    if Map.has_key?(local.entries_by_id, entry_id) do
      removed_entry = Map.fetch!(local.entries_by_id, entry_id)

      partitions = remove_from_set_and_drop_if_empty(local.partitions, partition, entry_id)
      pids = remove_from_set_and_drop_if_empty(local.pids, pid, entry_id)

      {
        Changes.leave(changes, removed_entry),
        %{
          local
          | entries_by_id: Map.delete(local.entries_by_id, entry_id),
            partitions: partitions,
            pids: pids
        }
      }
    else
      {changes, local}
    end
  end

  defp remove_from_set_and_drop_if_empty(map, key, value) do
    {_, new_map} =
      Map.get_and_update!(map, key, fn set ->
        new_set = MapSet.delete(set, value)

        if MapSet.size(new_set) == 0 do
          :pop
        else
          {set, new_set}
        end
      end)

    new_map
  end
end
