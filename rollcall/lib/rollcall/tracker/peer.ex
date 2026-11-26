defmodule Rollcall.Tracker.Peer do
  @moduledoc """
  The replication state that one tracker holds for one peer node.

  A peer holds the replica: the entries that the peer node tracked, as the
  tracker last heard them. The tracker never edits a replica. It replaces the
  replica from a snapshot, or applies a diff that starts at the mark. There is
  no merge, because each entry has one owner. See DESIGN.md: Receive messages
  and Detect a dead peer.

  `apply/2` takes a message and returns the new peer and the
  `Rollcall.Tracker.Changes` that the message made to the replica. 

  ## Fields

    * `replica` - the partition of each entry of the peer node, by ref. The ref
      is the identity. The replica holds no key and no meta. The view holds them.
      A diff names a leave by its ref. The replica gives the partition for the
      id of the leave.
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

  The transport can reorder, duplicate or lose messages. A stamp, the
  incarnation and the version of the sender, orders them. A stamp is newer when
  its incarnation is higher, or when the incarnations are equal and its version
  is higher.

  A diff applies only when it starts at the mark. If it does not, the tracker
  missed something, it's marked as `behind` and it asks for a snapshot. An applied
  diff does not clear `behind`, because it is always older than the message that 
  set the flag. The replica is still short of the peer.
  """
  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Messages
  alias Rollcall.Tracker.View

  @typedoc "The partition of each entry that the peer holds, by ref."
  @type replica :: %{Rollcall.ref() => Rollcall.partition()}

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
  because the diff applies to a state that the peer does not hold. A request
  does not create a peer.
  """
  @spec new(Messages.snapshot() | Messages.diff()) :: {t(), Changes.t()}
  def new({:snapshot, _origin, _stamp, _entries} = msg), do: __MODULE__.apply(%__MODULE__{}, msg)
  def new({:diff, _origin, _stamp, _from, _joins, _leaves} = msg), do: __MODULE__.apply(%__MODULE__{}, msg)

  @doc """
  Applies `message` to `peer`. Returns the new peer and the changes that the
  message made to the replica.

  Every message resets the silent count, including a stale message and a
  request. The peer is alive.

  A snapshot with a stamp newer than the mark replaces the replica, sets the
  mark and clears `behind`. Any other snapshot is stale and changes nothing.

  A diff that starts at the mark applies to the replica, and sets the mark. A
  diff with a newer stamp that does not start at the mark sets `behind` and
  changes nothing else. Any other diff is stale and changes nothing. An applied
  diff does not clear `behind`.

  A request carries no state, so it changes nothing. The tracker creates no peer
  for a request.

  The origin follows the newest incarnation. A message of an older run does not
  move it back.
  """
  @spec apply(t(), Messages.t()) :: {t(), Changes.t()}
  def apply(%__MODULE__{} = peer, message) do
    peer = %{peer | silent_ticks: 0}

    case message do
      {:snapshot, origin, stamp, entries} ->
        handle_snapshot(peer, origin, stamp, entries)

      {:diff, origin, stamp, from, joins, leaves} ->
        handle_diff(peer, origin, stamp, from, joins, leaves)

      {:request, _origin} ->
        handle_request(peer)
    end
  end

  @spec handle_snapshot(t(), pid(), Messages.stamp(), [Messages.wire_entry()]) :: {t(), Changes.t()}
  defp handle_snapshot(%__MODULE__{} = peer, origin, stamp, entries) do
    if newer?(stamp, peer.mark) do
      {peer, changes} = apply_snapshot(peer, entries)

      peer = %{peer | mark: stamp, behind: false}

      {put_origin(peer, origin, stamp), changes}
    else
      {peer, Changes.new()}
    end
  end

  @spec handle_diff(
          t(),
          pid(),
          Messages.stamp(),
          non_neg_integer(),
          [Messages.wire_entry()],
          [Rollcall.ref()]
        ) :: {t(), Changes.t()}
  defp handle_diff(%__MODULE__{} = peer, origin, stamp, from, joins, leaves) do
    case diff_status(stamp, from, peer.mark) do
      :applicable ->
        {peer, changes} = apply_diff(peer, joins, leaves)

        {put_origin(%{peer | mark: stamp}, origin, stamp), changes}

      :behind ->
        {put_origin(%{peer | behind: true}, origin, stamp), Changes.new()}

      :stale ->
        {peer, Changes.new()}
    end
  end

  @spec handle_request(t()) :: {t(), Changes.t()}
  defp handle_request(%__MODULE__{} = peer), do: {peer, Changes.new()}

  @doc "Returns the ids of the entries in the replica. The order is not defined."
  @spec entries(t()) :: [View.id()]
  def entries(%__MODULE__{replica: replica}), do: to_view_ids(replica)

  @doc "Returns true when the peer is holds no entries"
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{replica: replica}), do: map_size(replica) == 0

  @doc "Returns true when the peer knows it missed a message that is newer than its mark."
  @spec behind?(t()) :: boolean()
  def behind?(%__MODULE__{behind: behind}), do: behind

  @doc "Returns true if the peer holds entries and we haven't heard from it in more than 1 tick"
  @spec overdue?(t()) :: boolean()
  def overdue?(%__MODULE__{replica: replica, silent_ticks: silent_ticks}) do
    map_size(replica) > 0 and silent_ticks > 1
  end

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
      {:purge, Changes.new([], to_view_ids(peer.replica))}
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

  @spec apply_snapshot(t(), [Messages.wire_entry()]) :: {t(), Changes.t()}
  defp apply_snapshot(%__MODULE__{replica: old} = peer, entries) do
    joins = wire_to_new_entries(entries, old)
    new = wire_to_ref_map(entries)
    leaves = old |> Map.drop(Map.keys(new)) |> to_view_ids()

    {%{peer | replica: new}, Changes.new(joins, leaves)}
  end

  @spec apply_diff(t(), [Messages.wire_entry()], [Rollcall.ref()]) :: {t(), Changes.t()}
  defp apply_diff(peer, [], []), do: {peer, Changes.new()}

  defp apply_diff(%__MODULE__{replica: old} = peer, joins, leaves) do
    joined_refs_to_partition = wire_to_ref_map(joins)
    joined_entries = wire_to_new_entries(joins, old)

    # The changes come from the refs in the message, so a diff costs the size of
    # the diff and not the size of the replica. A join wins over a leave of the
    # same ref.
    left =
      old
      |> Map.take(leaves)
      |> Map.drop(Map.keys(joined_refs_to_partition))

    new = old |> Map.drop(Map.keys(left)) |> Map.merge(joined_refs_to_partition)

    {%{peer | replica: new},
     Changes.new(
       joined_entries,
       to_view_ids(left)
     )}
  end

  @spec to_view_ids(replica()) :: [View.id()]
  defp to_view_ids(replica), do: Enum.map(replica, fn {ref, partition} -> {partition, ref} end)

  @spec newer?(Messages.stamp(), Messages.stamp() | nil) :: boolean()
  defp newer?(_stamp, nil), do: true
  defp newer?({:stamp, incarnation_a, _}, {:stamp, incarnation_b, _}) when incarnation_a > incarnation_b, do: true
  defp newer?({:stamp, inc, version_a}, {:stamp, inc, version_b}), do: version_a > version_b
  defp newer?(_, _), do: false

  @spec diff_status(Messages.stamp(), non_neg_integer(), Messages.stamp() | nil) ::
          :applicable | :behind | :stale
  def diff_status(_diff_stamp, _diff_base_version, nil), do: :behind

  def diff_status(
        {:stamp, diff_inc, _diff_version} = diff_stamp,
        diff_base_version,
        {:stamp, peer_inc, peer_version} = mark
      ) do
    cond do
      diff_inc == peer_inc and diff_base_version == peer_version ->
        :applicable

      newer?(diff_stamp, mark) ->
        :behind

      true ->
        :stale
    end
  end

  @spec wire_to_ref_map([Messages.wire_entry()]) :: replica()
  defp wire_to_ref_map(entries) do
    Map.new(entries, fn {partition, ref, _key, _meta} -> {ref, partition} end)
  end

  @spec wire_to_new_entries([Messages.wire_entry()], replica()) :: [Rollcall.partitioned_entry()]
  defp wire_to_new_entries(entries, old) do
    for {_partition, ref, _key, _meta} = entry <- entries, not is_map_key(old, ref), do: entry
  end
end
