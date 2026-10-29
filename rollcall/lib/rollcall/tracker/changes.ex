defmodule Rollcall.Tracker.Changes do
  @moduledoc """
  The entries that one change added and removed.

  `joins` holds the entries that the change added. `leaves` holds the entries
  that the change removed. A replace has one leave and one join, so a
  subscriber sees the old entry leave and the new entry join in one diff.
  """

  alias Rollcall.Tracker.Entry

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

  @spec new([Entry.t()], [Entry.t()]) :: t()
  def new(joins, leaves) do
    %__MODULE__{joins: joins, leaves: leaves}
  end

  @doc "Returns true if changes are empty"
  def empty?(%__MODULE__{joins: [], leaves: []}), do: true
  def empty?(_changes), do: false

  @doc "Adds `entry` to the joins."
  @spec join(t(), Entry.t()) :: t()
  def join(%__MODULE__{} = changes, %Entry{} = entry) do
    %{changes | joins: [entry | changes.joins]}
  end

  @spec join_refs(t()) :: [Rollcall.ref()]
  def join_refs(%__MODULE__{joins: joins}) do
    Enum.map(joins, & &1.ref)
  end

  @spec leave_refs(t()) :: [Rollcall.ref()]
  def leave_refs(%__MODULE__{leaves: leaves}) do
    Enum.map(leaves, & &1.ref)
  end

  @doc "Adds `entry` to the leaves."
  @spec leave(t(), Entry.t()) :: t()
  def leave(%__MODULE__{} = changes, %Entry{} = entry) do
    %{changes | leaves: [entry | changes.leaves]}
  end
end
