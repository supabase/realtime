defmodule Rollcall.Tracker.View do
  @moduledoc """
  Provides a view of a Tracker's state.

  The view is represented as an ETS table. The table can only be updated
  by the tracker, but readers can access the table without going through
  the tracker process's mailbox.

  A row is `{{partition, ref}, key, meta}`. The table is an `ordered_set`, so
  the entries of one partition are one range of keys. 
  """

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.CommittedChanges

  @typedoc "The ETS table of a view."
  @type t :: :ets.tid()

  @typedoc """
  The id of an entry in the view: its partition and its ref.

  The id is the key of the ETS row. It is not the `Rollcall.key()` that a
  process tracks.
  """
  @type id :: {Rollcall.partition(), Rollcall.ref()}

  @doc """
  Returns a new, empty view table. 
  """
  @spec new() :: t()
  def new do
    :ets.new(:view, [:ordered_set, :protected, read_concurrency: true, write_concurrency: :auto])
  end

  @doc """
  Returns every entry in the view, with its partition. 

  Returns `[]` when the table does not exist. 
  """
  @spec entries(t()) :: [Rollcall.partitioned_entry()]
  def entries(table) do
    # fn {{partition, ref}, key, meta} -> {partition, ref, key, meta}
    :ets.select(table, [
      {
        {{:"$1", :"$2"}, :"$3", :"$4"},
        [],
        [{{:"$1", :"$2", :"$3", :"$4"}}]
      }
    ])
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the entries in `partition`.

  Returns `[]` when the table does not exist.
  """
  @spec entries(t(), Rollcall.partition()) :: [Rollcall.entry()]
  def entries(table, partition) do
    # fn {{^partition, ref}, key, meta} -> {ref, key, meta}
    :ets.select(table, [
      {
        {{partition, :"$1"}, :"$2", :"$3"},
        [],
        [{{:"$1", :"$2", :"$3"}}]
      }
    ])
  rescue
    ArgumentError -> []
  end

  @doc """
  Returns the entry of each id in `ids`, with its partition.

  The tracker uses this to read the entries that `Rollcall.Tracker.Local`
  holds by id. `Local` does not keep the meta of an entry. The view does.

  The result has the order of `ids`. Each id must name an entry in the view.
  """
  @spec fetch(t(), [id()]) :: [Rollcall.partitioned_entry()]
  def fetch(table, ids) do
    Enum.map(ids, fn id ->
      [{{partition, ref} = ^id, key, meta}] = :ets.lookup(table, id)

      {partition, ref, key, meta}
    end)
  end

  @doc """
  Returns the number of entries in each partition that has an entry.

  Returns `%{}` when the table does not exist.
  """
  @spec partition_counts(t()) :: %{Rollcall.partition() => pos_integer()}
  def partition_counts(table) do
    # fn {{partition, _ref}, _key, _meta} -> partition
    table
    |> :ets.select([{{{:"$1", :_}, :_, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Returns the refs of the entries in each partition that has an entry.

  Returns `%{}` when the table does not exist.
  """
  @spec refs(t()) :: %{Rollcall.partition() => [Rollcall.ref()]}
  def refs(table) do
    # fn {{partition, ref}, _key, _meta} -> {partition, ref}
    table
    |> :ets.select([
      {
        {{:"$1", :"$2"}, :_, :_},
        [],
        [{{:"$1", :"$2"}}]
      }
    ])
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Returns the refs of the entries in `partition`.

  Returns `[]` when the table does not exist.
  """
  @spec refs(t(), Rollcall.partition()) :: [Rollcall.ref()]
  def refs(table, partition) do
    # fn {{^partition, ref}, _key, _meta} -> ref
    table
    |> :ets.select([
      {
        {{partition, :"$1"}, :_, :_},
        [],
        [:"$1"]
      }
    ])
  rescue
    ArgumentError -> []
  end

  @doc """
  Applies `changes` to the view and returns the committed changes.

  The function deletes the entry of each leave and returns it in the `leaves`
  of the result, with its key and meta. Then it inserts the joins. 

  Raises when a leave has no entry.
  """
  @spec write(t(), Changes.t()) :: CommittedChanges.t()
  def write(table, changes) do
    leaves = Changes.leaves(changes)
    joins = Changes.joins(changes)

    left =
      for id <- leaves do
        {partition, ref} = id
        [{^id, key, meta}] = :ets.take(table, id)
        {partition, ref, key, meta}
      end

    :ets.insert(
      table,
      for {partition, ref, key, meta} <- joins do
        {{partition, ref}, key, meta}
      end
    )

    %CommittedChanges{joins: joins, leaves: left}
  end
end
