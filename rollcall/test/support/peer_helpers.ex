defmodule Rollcall.PeerHelpers do
  @moduledoc """
  Reads the values that a `Rollcall.Tracker.Peer` returns, and starts the
  processes that the tests need.

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

  @doc """
  Returns a pid on `node` with the id `id`. Use a different `id` for each pid.

  The node does not need to exist. Do not send a message to the pid or call a
  `Process` function on it.
  """
  @spec remote_pid(node(), pos_integer()) :: pid()
  def remote_pid(node, id) do
    name = Atom.to_string(node)

    :erlang.binary_to_term(<<131, 88, 119, byte_size(name), name::binary, id::32, 0::32, 1::32>>)
  end

  @doc """
  Starts a tracker for `scope` under the test supervisor. The tracker uses
  `silence_threshold` as its silence threshold.

  This function is the only place that passes the init parameter.
  """
  @spec start_tracker(Rollcall.scope(), pos_integer()) :: pid()
  def start_tracker(scope, silence_threshold) do
    ExUnit.Callbacks.start_supervised!({Rollcall.Tracker, {scope, silence_threshold: silence_threshold}})
  end

  @doc """
  Returns the events in `trace` that have one of `kinds` and the given `scope`.
  Fails the test unless there are exactly `count` events.

  The failure message lists the events of these kinds that have another scope,
  and the number of events of each kind in the trace. A wrong scope or a
  missing trace point is then visible at once.
  """
  @spec expect_events(list(), atom() | [atom()], term(), non_neg_integer()) :: [map()]
  def expect_events(trace, kinds, scope, count) do
    kinds = List.wrap(kinds)
    {matching, other_scope} = trace |> Snabbkaffex.of_kind(kinds) |> Enum.split_with(&(&1.scope == scope))

    if length(matching) == count do
      matching
    else
      ExUnit.Assertions.flunk("""
      Expected #{count} event(s) of #{inspect(kinds)} for the scope #{inspect(scope)}, found #{length(matching)}.

      #{event_list("Events for this scope", matching)}
      #{event_list("Events of these kinds for another scope", other_scope)}
      #{kind_counts(trace)}
      """)
    end
  end

  defp event_list(title, []), do: "#{title}: none"

  defp event_list(title, events) do
    "#{title}:\n" <> Enum.map_join(events, "\n", &("  " <> inspect(Map.delete(&1, :"~meta"), limit: 10)))
  end

  defp kind_counts(trace) do
    counts =
      trace
      |> Enum.frequencies_by(& &1[:"$kind"])
      |> Enum.map_join(", ", fn {kind, count} -> "#{kind}: #{count}" end)

    "Events in the trace by kind: #{counts}"
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
