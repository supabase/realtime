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

  @typedoc "The ETS table of a view."
  @type t :: :ets.tid()

  @typedoc "An entry in one partition."
  @type entry :: {Rollcall.ref(), Rollcall.key(), Rollcall.meta()}

  @typedoc "An entry in the scope, with its partition."
  @type scope_entry :: {Rollcall.partition(), Rollcall.ref(), Rollcall.key(), Rollcall.meta()}

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
  @spec entries(t()) :: [scope_entry()]
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
  Returns the entries in `partition`.

  Returns `[]` when the table does not exist.
  """
  @spec entries(t(), Rollcall.partition()) :: [entry()]
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
  Applies `changes` to the view. 
  """
  @spec write(t(), Changes.t()) :: :ok
  def write(table, %Changes{joins: joins, leaves: leaves}) do
    :ets.insert(
      table,
      for join <- joins do
        {{join.partition, join.ref}, join.key, join.meta}
      end
    )

    for leave <- leaves do
      :ets.delete(table, {leave.partition, leave.ref})
    end

    :ok
  end
end
