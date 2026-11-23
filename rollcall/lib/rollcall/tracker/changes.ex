defmodule Rollcall.Tracker.Changes do
  @moduledoc """
  The entries that one change added and removed.

  `joins` holds the entries that the change added. `leaves` holds the ids of
  the entries that the change removed. A replace has one leave and one join, so
  a subscriber sees the old entry leave and the new entry join in one diff.

  A leave has no key and no meta. `Rollcall.Tracker.View.write/2` deletes the
  entry of each leave and returns it in `Rollcall.Tracker.CommittedChanges`.
  """

  alias Rollcall.Tracker.View

  defstruct joins: [], leaves: []

  @type t :: %__MODULE__{
          joins: [Rollcall.partitioned_entry()],
          leaves: [View.id()]
        }

  @doc "Returns changes with no join and no leave."
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc "Returns changes with the given `joins` and `leaves`."
  @spec new([Rollcall.partitioned_entry()], [View.id()]) :: t()
  def new(joins, leaves) do
    %__MODULE__{joins: joins, leaves: leaves}
  end

  @doc "Returns true when `changes` have no join and no leave."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{joins: [], leaves: []}), do: true
  def empty?(_changes), do: false

  @doc "Adds `entry` to the joins."
  @spec join(t(), Rollcall.partitioned_entry()) :: t()
  def join(%__MODULE__{} = changes, {_partition, _ref, _key, _meta} = entry) do
    %{changes | joins: [entry | changes.joins]}
  end

  @doc "Returns the refs of the joins."
  @spec join_refs(t()) :: [Rollcall.ref()]
  def join_refs(%__MODULE__{joins: joins}) do
    Enum.map(joins, fn {_partition, ref, _key, _meta} -> ref end)
  end

  @doc "Returns the refs of the leaves."
  @spec leave_refs(t()) :: [Rollcall.ref()]
  def leave_refs(%__MODULE__{leaves: leaves}) do
    Enum.map(leaves, fn {_partition, ref} -> ref end)
  end

  @doc "Adds `entry` to the leaves."
  @spec leave(t(), View.id()) :: t()
  def leave(%__MODULE__{} = changes, {_partition, _ref} = leave) do
    %{changes | leaves: [leave | changes.leaves]}
  end
end
