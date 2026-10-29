defmodule Rollcall.Tracker.Peer do
  @moduledoc """
  The replication state that one tracker holds for one peer node.

  A peer holds the replica: the entries that the peer node tracked, as the
  tracker last heard them. The tracker never edits a replica. It replaces the
  replica from a snapshot, or applies a diff that starts at the mark. There is
  no merge, because each entry has one owner. See DESIGN.md: Receive messages
  and Detect a dead peer.

  `deliver/2` takes a message and returns the new peer and the `Rollcall.Tracker.Changes` 
  that the message made to the replica. The tracker creates a peer from the first snapshot 
  or diff of a node with `new/1`, and deletes the peer when `tick/2` purges it.

  ## Fields

    * `replica` - the entries of the peer node, by ref. Each entry has the origin
      as its pid, because the pid of a remote process has no use on this node.
      The ref is the identity.
    * `mark` - the stamp of the message that gave the replica. It is `nil` until
      the first snapshot. A diff cannot set it on an empty replica, because the
      mark says that the replica is the state of the peer at that stamp.
    * `behind` - true when a message showed that the tracker missed a newer
      state. Only a snapshot clears it.
    * `silent_ticks` - the number of ticks since the last message.
    * `origin` - the pid of the tracker of the newest incarnation that sent a
      message. The tracker sends its request to this pid.
    * `origin_incarnation` - the incarnation of the origin.

  ## Order of messages

  The transport can reorder, duplicate or loses messages. A stamp, the
  incarnation and the version of the sender, orders them. A stamp is newer when
  its incarnation is higher, or when the incarnations are equal and its version
  is higher.

  A diff applies only when it starts at the mark. If it does not, the tracker
  missed something, it's marked as `behind` and it asks for a snapshot. An applied
  diff does not clear `behind`, because it is always older than the message that 
  set the flag. The replica is still short of the peer.
  """
  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Entry
  alias Rollcall.Tracker.Messages

  @typedoc "The entries that a peer holds, by ref."
  @type replica :: %{Rollcall.ref() => Entry.t()}

  @typedoc "The replication state of one peer node."
  @type t :: %__MODULE__{
          replica: replica(),
          mark: Messages.stamp() | nil,
          silent_ticks: non_neg_integer(),
          behind: boolean(),
          origin: pid() | nil,
          origin_incarnation: integer() | nil
        }

  defstruct origin: nil, origin_incarnation: nil, mark: nil, silent_ticks: 0, behind: false, replica: %{}

  @doc """
  Returns the peer for the first snapshot or diff from a node, and the changes
  that the message made.

  A snapshot gives the replica. A diff gives an empty replica that is behind,
  because the diff applies to a state that the peer does not hold.
  """
  @spec new(Messages.snapshot() | Messages.diff()) :: {t(), Changes.t()}
  def new({:snapshot, _origin, _stamp, _entries} = msg), do: deliver(%__MODULE__{}, msg)
  def new({:diff, _origin, _stamp, _from, _joins, _leaves} = msg), do: deliver(%__MODULE__{}, msg)

  @doc """
  Applies `message` to `peer`. Returns the new peer and the changes that the
  message made to the replica.

  Every message resets the silent count. The rules:

    * A snapshot with a stamp newer than the mark replaces the replica and
      clears `behind`.
    * A diff that starts at the mark applies to the replica.
    * A diff with a newer stamp that does not start at the mark sets `behind`.
    * Any other snapshot or diff is stale and changes nothing.
    * A request changes nothing.

  The origin follows the newest incarnation. A message of an older run does not
  move it back.
  """
  @spec deliver(t(), Messages.t()) :: {t(), Changes.t()}
  def deliver(%__MODULE__{} = peer, msg) do
    do_deliver(%{peer | silent_ticks: 0}, msg)
  end

  @spec do_deliver(t(), Messages.t()) :: {t(), Changes.t()}
  defp do_deliver(%__MODULE__{} = peer, {:snapshot, origin, stamp, entries}) do
    if newer?(stamp, peer.mark) do
      {peer, changes} = apply_snapshot(peer, origin, entries)

      peer = %{peer | mark: stamp, behind: false}

      {put_origin(peer, origin, stamp), changes}
    else
      {peer, Changes.new()}
    end
  end

  defp do_deliver(%__MODULE__{} = peer, {:diff, origin, stamp, from, joins, leaves}) do
    case diff_status(stamp, from, peer.mark) do
      :applicable ->
        {peer, changes} = apply_diff(peer, origin, joins, leaves)

        {put_origin(%{peer | mark: stamp}, origin, stamp), changes}

      :behind ->
        {put_origin(%{peer | behind: true}, origin, stamp), Changes.new()}

      :stale ->
        {peer, Changes.new()}
    end
  end

  defp do_deliver(%__MODULE__{} = peer, {:request, _origin}) do
    {peer, Changes.new()}
  end

  @doc "Returns the entries in the replica."
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{replica: replica}), do: Map.values(replica)

  @doc "Returns true when the peer knows it missed a message that is newer than its mark."
  @spec behind?(t()) :: boolean()
  def behind?(%__MODULE__{behind: behind}), do: behind

  @doc "Returns the stamp of the message that gave the replica, or `nil` before the first snapshot."
  @spec mark(t()) :: Messages.stamp() | nil
  def mark(%__MODULE__{mark: mark}), do: mark

  @doc "Returns the pid of the tracker of the newest incarnation that sent a message."
  @spec origin(t()) :: pid() | nil
  def origin(%__MODULE__{origin: origin}), do: origin

  @doc """
  Counts one quiet period. 

  Returns `{:keep, peer}`, or `{:purge, changes}` when the count reaches `threshold`.

  A purge returns every entry in the replica as a leave. The tracker deletes the
  peer, so the purge returns no peer.
  """
  @spec tick(t(), pos_integer()) :: {:keep, t()} | {:purge, Changes.t()}
  def tick(%__MODULE__{} = peer, threshold) do
    new_ticks = peer.silent_ticks + 1

    if new_ticks < threshold do
      {:keep, %{peer | silent_ticks: new_ticks}}
    else
      {:purge, Changes.new([], Map.values(peer.replica))}
    end
  end

  # The origin follows the newest incarnation. A message of an older run can
  # still be accepted when it is newer than the mark, and must not point the
  # origin back at that run.
  @spec put_origin(t(), pid(), Messages.stamp()) :: t()
  defp put_origin(%__MODULE__{origin_incarnation: current} = peer, origin, {:stamp, incarnation, _version})
       when is_nil(current) or incarnation >= current do
    %{peer | origin: origin, origin_incarnation: incarnation}
  end

  defp put_origin(%__MODULE__{} = peer, _origin, _stamp), do: peer

  @spec apply_snapshot(t(), pid(), [Messages.wire_entry()]) :: {t(), Changes.t()}
  defp apply_snapshot(%__MODULE__{} = peer, origin, entries) do
    old = peer.replica

    new = wire_entries_to_entries(entries, origin)

    {%{peer | replica: new}, diff_replicas(old, new)}
  end

  @spec apply_diff(t(), pid(), [Messages.wire_entry()], [Rollcall.ref()]) :: {t(), Changes.t()}
  defp apply_diff(%__MODULE__{} = peer, origin, joins, leaves) do
    old = peer.replica

    join_entries = wire_entries_to_entries(joins, origin)

    new = old |> Map.drop(leaves) |> Map.merge(join_entries)

    {%{peer | replica: new}, diff_replicas(old, new)}
  end

  @spec diff_replicas(replica(), replica()) :: Changes.t()
  defp diff_replicas(old, new) do
    old_keys = MapSet.new(Map.keys(old))
    new_keys = MapSet.new(Map.keys(new))

    join_keys = MapSet.difference(new_keys, old_keys) |> MapSet.to_list()
    left_keys = MapSet.difference(old_keys, new_keys) |> MapSet.to_list()

    joins = new |> Map.take(join_keys) |> Map.values()
    leaves = old |> Map.take(left_keys) |> Map.values()

    Changes.new(joins, leaves)
  end

  @spec wire_entries_to_entries([Messages.wire_entry()], pid()) :: replica()
  defp wire_entries_to_entries(wire_entries, origin) do
    wire_entries
    |> Enum.map(fn
      {partition, key, ref, meta} -> Entry.new(origin, partition, key, meta, ref)
    end)
    |> Enum.reduce(%{}, fn e, acc -> Map.put(acc, e.ref, e) end)
  end

  @spec newer?(Messages.stamp(), Messages.stamp() | nil) :: boolean()
  defp newer?(_stamp, nil), do: true
  defp newer?({:stamp, incarnation_a, _}, {:stamp, incarnation_b, _}) when incarnation_a > incarnation_b, do: true
  defp newer?({:stamp, inc, version_a}, {:stamp, inc, version_b}), do: version_a > version_b
  defp newer?(_, _), do: false

  @spec diff_status(Messages.stamp(), non_neg_integer(), Messages.stamp() | nil) ::
          :applicable | :behind | :stale
  defp diff_status(
         {:stamp, incarnation, _version},
         base_version,
         {:stamp, incarnation, base_version}
       ),
       do: :applicable

  defp diff_status(diff_stamp, _base, current_mark) do
    if newer?(diff_stamp, current_mark) do
      :behind
    else
      :stale
    end
  end
end
