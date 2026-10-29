defmodule Rollcall.PeerHelpers do
  @moduledoc """
  Reads the values that a `Rollcall.Tracker.Peer` returns.

  The tests build messages with `Rollcall.Tracker.Messages`. A wire entry has
  no pid. A peer sets the pid of each entry it holds to the origin of the
  message that carried the entry.
  """

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Messages
  alias Rollcall.Tracker.Peer

  @doc "Returns a pid for an origin. The pid does not need to be alive."
  @spec new_pid() :: pid()
  def new_pid do
    spawn(fn -> :ok end)
  end

  @doc "Returns `{incarnation, version}` for `stamp`."
  @spec stamp_tuple(Messages.stamp()) :: {integer(), non_neg_integer()}
  def stamp_tuple({:stamp, incarnation, version}), do: {incarnation, version}

  @doc "Returns the sorted refs of the entries that `changes` added."
  @spec joins(term()) :: [Rollcall.ref()]
  def joins(changes), do: changes |> Changes.join_refs() |> Enum.sort()

  @doc "Returns the sorted refs of the entries that `changes` removed."
  @spec leaves(term()) :: [Rollcall.ref()]
  def leaves(changes), do: changes |> Changes.leave_refs() |> Enum.sort()

  @doc "Returns the sorted refs of the entries that `peer` holds."
  @spec refs(Peer.t()) :: [Rollcall.ref()]
  def refs(peer) do
    peer |> Peer.entries() |> Enum.map(& &1.ref) |> Enum.sort()
  end

  @doc "Returns the pid of each entry that `peer` holds."
  @spec origins(Peer.t()) :: [pid()]
  def origins(peer) do
    peer |> Peer.entries() |> Enum.map(& &1.pid)
  end

  @doc "Returns `{incarnation, version}` of the mark of `peer`, or `nil`."
  @spec mark_tuple(Peer.t()) :: {integer(), non_neg_integer()} | nil
  def mark_tuple(peer) do
    case Peer.mark(peer) do
      nil -> nil
      stamp -> stamp_tuple(stamp)
    end
  end
end
