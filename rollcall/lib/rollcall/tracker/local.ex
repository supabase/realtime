defmodule Rollcall.Tracker.Local do
  @moduledoc """
  The entries that the processes on this node track in one tracker.

  `Local` is a pure data structure. Each function returns the new set. A test
  of the set needs no process.

  A function that changes the set also returns the `Rollcall.Tracker.Changes`
  that the change made. The tracker writes these changes to the view and
  publishes them to subscribers.

  `Local` holds the ref of each entry, by pid, partition and key. It does not
  hold the meta. The view holds the key, the ref and the meta of every entry.

  The caller names an entry by its pid, its partition and its key. A pid has one
  entry for each partition and key. `Local` uses this name to find the ref of
  the entry that a track replaces or an untrack removes.

  `ids/1` returns the view id of each entry: `{partition, ref}`. The tracker
  reads the entries of these ids from the view to build a snapshot. `Local`
  does not read the entries of a partition. The view does.

  The `entries` field is a map by pid. `untrack_pid/2` depends on the entries of
  that pid, and not on all entries. A function removes a pid from the map when
  the pid has no entry. The map then does not grow with the number of processes
  that tracked an entry in the past.
  """

  alias Rollcall.Tracker.View
  alias Rollcall.Tracker.Changes

  defstruct entries: %{}

  @prev_ref_key :rc_prev_ref

  @typedoc """
  The entries of this node. The map goes from a pid to its entries. The map of
  a pid goes from `{partition, key}` to the ref of the entry.
  """
  @opaque t :: %__MODULE__{
            entries: %{pid() => %{{Rollcall.partition(), Rollcall.key()} => Rollcall.ref()}}
          }

  @doc "Returns an empty set."
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc "Returns true when the set holds no entry."
  @spec empty?(t()) :: boolean()
  def empty?(local) do
    map_size(local.entries) == 0
  end

  @doc """
  Returns the view id of every entry in `local`: `{partition, ref}`.

  The order is not defined.
  """
  @spec ids(t()) :: [View.id()]
  def ids(%__MODULE__{entries: entries}) do
    entries
    |> Enum.flat_map(fn {_pid, ref_map} ->
      Enum.map(ref_map, fn {{partition, _key}, ref} ->
        {partition, ref}
      end)
    end)
  end

  @doc """
  Adds an entry with `ref` for `pid`, `key` and `meta` in `partition`.

  When `pid` already has an entry for `key` in `partition`, the new entry
  replaces it. The old entry is a leave and the new entry is a join. The new
  entry has `ref` even when the meta is the same.

  A leave is the view id of the old entry. A join holds the partition, the ref,
  the key and the meta. `Local` does not keep the meta.

  A replacement adds the key `:rc_prev_ref` to the new meta. Its value is the
  ref of the replaced entry. The function overwrites a `:rc_prev_ref` key that
  the caller put in the meta. A first track does not add the key. The key stays
  in the meta until the entry is replaced or removed.
  """
  @spec track(t(), pid(), Rollcall.partition(), Rollcall.key(), Rollcall.meta(), Rollcall.ref()) ::
          {Changes.t(), t()}
  def track(local, pid, partition, key, meta, ref) do
    meta = with_prev_ref(meta, local, pid, partition, key)

    {Changes.new(), local}
    |> remove_entry(pid, partition, key)
    |> add_entry(pid, partition, key, ref, meta)
  end

  @doc "Returns true when `pid` has at least one entry."
  @spec tracks?(t(), pid()) :: boolean()
  def tracks?(local, pid) do
    Map.has_key?(local.entries, pid)
  end

  @doc """
  Removes the entry of `pid` for `key` in `partition`.

  The removed entry is a leave. A leave is the view id of the entry. When no
  entry matches, the changes are empty and the set does not change.
  """
  @spec untrack(t(), pid(), Rollcall.partition(), Rollcall.key()) :: {Changes.t(), t()}
  def untrack(local, pid, partition, key) do
    remove_entry({Changes.new(), local}, pid, partition, key)
  end

  @doc """
  Removes all entries of `pid` in all partitions.

  Each removed entry is a leave. A leave is the view id of the entry. When `pid`
  has no entry, the changes are empty and the set does not change.
  """
  @spec untrack_pid(t(), pid()) :: {Changes.t(), t()}
  def untrack_pid(local, pid) do
    {pid_entries, entries} = Map.pop(local.entries, pid, %{})

    changes =
      pid_entries
      |> Enum.reduce(Changes.new(), fn {{partition, _key}, ref}, acc ->
        Changes.leave(acc, {partition, ref})
      end)

    {changes, %{local | entries: entries}}
  end

  defp add_entry({changes, local}, pid, partition, key, ref, meta) do
    entries = Map.update(local.entries, pid, %{{partition, key} => ref}, &Map.put(&1, {partition, key}, ref))

    {
      Changes.join(changes, {partition, ref, key, meta}),
      %{
        local
        | entries: entries
      }
    }
  end

  defp remove_entry({changes, local}, pid, partition, key) do
    if Map.has_key?(local.entries, pid) do
      ref_key = {partition, key}

      {old_refs, new_entries} =
        Map.get_and_update!(local.entries, pid, fn pid_entries ->
          new_entries = Map.delete(pid_entries, ref_key)

          case map_size(new_entries) do
            0 -> :pop
            _ -> {pid_entries, new_entries}
          end
        end)

      changes =
        case Map.get(old_refs, ref_key) do
          nil -> changes
          ref -> Changes.leave(changes, {partition, ref})
        end

      {changes, %{local | entries: new_entries}}
    else
      {changes, local}
    end
  end

  defp with_prev_ref(meta, %__MODULE__{entries: entries}, pid, partition, key) do
    case entries |> Map.get(pid, %{}) |> Map.get({partition, key}) do
      nil -> meta
      ref -> Map.put(meta, @prev_ref_key, ref)
    end
  end
end
