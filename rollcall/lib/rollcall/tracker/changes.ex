defmodule Rollcall.Tracker.Changes do
  @moduledoc """
  The entries that one change added and removed.

  `joins` holds the entries that the change added. `leaves` holds the ids of
  the entries that the change removed. A replace has one leave and one join, so
  a subscriber sees the old entry leave and the new entry join in one diff.

  A leave has no key and no meta. `Rollcall.Tracker.View.write/2` deletes the
  entry of each leave and returns it in `Rollcall.Tracker.CommittedChanges`.

  `merge/2` combines the changes of several operations into one net change.

  Use the functions of this module to build and read changes.
  """

  alias Rollcall.Tracker.View

  @enforce_keys [:joins, :leaves]
  defstruct [:joins, :leaves]

  @opaque t :: %__MODULE__{
            joins: %{View.id() => {Rollcall.key(), Rollcall.meta()}},
            leaves: %{View.id() => true}
          }

  @doc "Returns changes with no join and no leave."
  @spec new() :: t()
  def new, do: %__MODULE__{joins: %{}, leaves: %{}}

  @doc "Returns changes with the given `joins` and `leaves`."
  @spec new([Rollcall.partitioned_entry()], [View.id()]) :: t()
  def new(joins, leaves) do
    %__MODULE__{
      joins: Map.new(joins, fn {partition, ref, key, meta} -> {{partition, ref}, {key, meta}} end),
      leaves: Map.new(leaves, fn {partition, ref} -> {{partition, ref}, true} end)
    }
  end

  @doc "Returns true when `changes` have no join and no leave."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{joins: joins, leaves: leaves}), do: joins == %{} and leaves == %{}

  @doc "Adds `entry` to the joins."
  @spec join(t(), Rollcall.partitioned_entry()) :: t()
  def join(%__MODULE__{joins: joins} = changes, {partition, ref, key, meta}) do
    %{changes | joins: Map.put(joins, {partition, ref}, {key, meta})}
  end

  @doc "Returns the joins as partitioned entries. The order is not defined."
  @spec joins(t()) :: [Rollcall.partitioned_entry()]
  def joins(%__MODULE__{joins: joins}) when joins == %{}, do: []

  def joins(%__MODULE__{joins: joins}) do
    Enum.map(joins, fn {{partition, ref}, {key, meta}} -> {partition, ref, key, meta} end)
  end

  @doc "Returns the refs of the joins."
  @spec join_refs(t()) :: [Rollcall.ref()]
  def join_refs(%__MODULE__{joins: joins}) when joins == %{}, do: []

  def join_refs(%__MODULE__{joins: joins}) do
    joins
    |> Map.keys()
    |> Enum.map(&elem(&1, 1))
  end

  @doc "Returns the refs of the leaves."
  @spec leave_refs(t()) :: [Rollcall.ref()]
  def leave_refs(%__MODULE__{leaves: leaves}) when leaves == %{}, do: []

  def leave_refs(%__MODULE__{leaves: leaves}) do
    Enum.map(leaves, fn {{_partition, ref}, _} -> ref end)
  end

  @doc "Returns the ids of the leaves. The order is not defined."
  @spec leaves(t()) :: [View.id()]
  def leaves(%__MODULE__{leaves: leaves}), do: Map.keys(leaves)

  @doc "Adds `entry` to the leaves."
  @spec leave(t(), View.id()) :: t()
  def leave(%__MODULE__{leaves: leaves} = changes, {_partition, _ref} = leave) do
    %{changes | leaves: Map.put(leaves, leave, true)}
  end

  @doc """
  Returns the net change of `earlier` followed by `later`.

  An entry that `earlier` joins and `later` leaves is in neither list of the
  result. Each ref is unique, so no ref is both a join and a leave.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = c1, %__MODULE__{} = c2) do
    joined = %{c1 | joins: Map.merge(c1.joins, c2.joins)}

    Enum.reduce(c2.leaves, joined, fn {id, true}, acc ->
      if Map.has_key?(acc.joins, id) do
        %{acc | joins: Map.delete(acc.joins, id)}
      else
        %{acc | leaves: Map.put(acc.leaves, id, true)}
      end
    end)
  end
end
