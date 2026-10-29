defmodule Rollcall.Tracker.Messages do
  @moduledoc """
  The messages that the trackers of one scope send to each other.

  A message is a tuple. The first element is the kind. The second element is
  the origin: the pid of the tracker that sent the message. The receiver finds
  the peer record with `node(origin)`.

  A snapshot and a diff carry the stamp of the sender. A request carries no
  stamp.

  An entry on the wire is a tuple of the partition, the key, the ref and the
  meta. The wire entry has no pid. The receiver sets the pid of the entry to the
  origin of the message. A diff lists its leaves as refs, because the receiver
  holds the entries already.

  See DESIGN.md: Messages.
  """

  @typedoc "The pid of the tracker that sent the message."
  @type origin :: pid()

  @typedoc """
  The incarnation and the version of the sender.

  The incarnation is the time at which the tracker started. The version counts
  the local changes since then.
  """
  @type stamp :: {:stamp, integer(), non_neg_integer()}

  @typedoc "An entry on the wire: the partition, the key, the ref and the meta."
  @type wire_entry :: {Rollcall.partition(), Rollcall.key(), Rollcall.ref(), Rollcall.meta()}

  @typedoc "The full `local` set of the sender."
  @type snapshot :: {:snapshot, origin(), stamp(), [wire_entry()]}

  @typedoc """
  The change from the last heartbeat of the sender to its current state.

  `from` is the version of the last heartbeat.
  """
  @type diff ::
          {:diff, origin(), stamp(), from :: non_neg_integer(), joins :: [wire_entry()], leaves :: [Rollcall.ref()]}

  @typedoc "A request for a snapshot."
  @type request :: {:request, origin()}

  @typedoc "A snapshot, a diff or a request."
  @type t :: snapshot() | diff() | request()

  @doc "Returns the stamp for `incarnation` and `version`."
  @spec stamp(integer(), non_neg_integer()) :: stamp()
  def stamp(incarnation, version), do: {:stamp, incarnation, version}

  @doc "Returns the entry on the wire."
  @spec wire_entry(Rollcall.partition(), Rollcall.key(), Rollcall.ref(), Rollcall.meta()) :: wire_entry()
  def wire_entry(partition, key, ref, meta), do: {partition, key, ref, meta}

  @doc "Returns a snapshot with `entries`."
  @spec snapshot(origin(), stamp(), [wire_entry()]) :: snapshot()
  def snapshot(origin, stamp, entries), do: {:snapshot, origin, stamp, entries}

  @doc "Returns a diff that applies to the version `from`."
  @spec diff(origin(), stamp(), non_neg_integer(), [wire_entry()], [Rollcall.ref()]) :: diff()
  def diff(origin, stamp, from, joins, leaves), do: {:diff, origin, stamp, from, joins, leaves}

  @doc "Returns a request for a snapshot."
  @spec request(origin()) :: request()
  def request(origin), do: {:request, origin}

  @doc "Returns the origin of `message`."
  @spec origin(t()) :: origin()
  def origin({:snapshot, origin, _stamp, _entries}), do: origin
  def origin({:diff, origin, _stamp, _from, _joins, _leaves}), do: origin
  def origin({:request, origin}), do: origin
end
