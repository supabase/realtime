defmodule Rollcall.Tracker.Peer do
  @moduledoc """
  Tracks the replication state of a peer.

  This closely matches the peers in the TLA+ model described in DESIGN.md.

  This module handles receiving messages from the remote peer,
  tracking the `mark` which records the last state we're up to,
  whether we're `behind` the remote peer, and the actual replicated
  data which is a map from `ref` to `Entry`.

  We also track the origin so we know where the remote peer is.

  """
  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Entry
  alias Rollcall.Tracker.Messages

  @type incarnation :: pos_integer()
  @type version :: non_neg_integer()
  @type t :: %__MODULE__{
          replica: %{Rollcall.ref() => Entry.t()},
          mark: Messages.stamp() | nil,
          silent_ticks: non_neg_integer(),
          behind: boolean(),
          origin: pid()
        }

  defstruct origin: nil, mark: nil, silent_ticks: 0, behind: false, replica: %{}

  def new(msg) do
    deliver(%__MODULE__{}, msg)
  end

  def deliver(%__MODULE__{} = peer, {:snapshot, origin, stamp, entries}) do
    peer = %{peer | silent_ticks: 0}

    if newer?(stamp, peer.mark) do
      {peer, changes} = apply_snapshot(peer, origin, entries)

      {
        %{
          peer
          | origin: origin,
            mark: stamp,
            behind: false,
            silent_ticks: 0
        },
        changes
      }
    else
      {peer, Changes.new()}
    end
  end

  def deliver(%__MODULE__{} = peer, {:diff, origin, stamp, from, joins, leaves}) do
    case diff_status(stamp, from, peer.mark) do
      :applicable ->
        {peer, changes} = apply_diff(peer, origin, joins, leaves)

        {%{peer | origin: origin, mark: stamp, silent_ticks: 0}, changes}

      :behind ->
        {%{peer | behind: true, origin: origin}, Changes.new()}

      :stale ->
        {peer, Changes.new()}
    end
  end

  def deliver(peer, {:request, _origin}) do
    {%{peer | silent_ticks: 0}, Changes.new()}
  end

  def deliver(peer, _msg) do
    {peer, Changes.new()}
  end

  def entries(peer) do
    peer.replica |> Map.values()
  end

  def behind?(%__MODULE__{behind: behind}), do: behind

  def mark(%__MODULE__{mark: mark}), do: mark

  def origin(%__MODULE__{origin: origin}), do: origin

  @spec tick(t(), non_neg_integer()) :: {:keep, t()} | {:purge, Changes.t()}
  def tick(peer, threshold) do
    new_ticks = peer.silent_ticks + 1

    if new_ticks < threshold do
      {:keep, %{peer | silent_ticks: new_ticks}}
    else
      {:purge, Changes.new([], Map.values(peer.replica))}
    end
  end

  defp apply_snapshot(peer, origin, entries) do
    old = peer.replica

    new = wire_entries_to_entries(entries, origin)

    {%{peer | replica: new}, diff_replicas(old, new)}
  end

  defp apply_diff(peer, origin, joins, leaves) do
    old = peer.replica

    join_entries = wire_entries_to_entries(joins, origin)

    new = old |> Map.drop(leaves) |> Map.merge(join_entries)

    {%{peer | replica: new}, diff_replicas(old, new)}
  end

  defp diff_replicas(old, new) do
    old_keys = MapSet.new(Map.keys(old))
    new_keys = MapSet.new(Map.keys(new))

    join_keys = MapSet.difference(new_keys, old_keys) |> MapSet.to_list()
    left_keys = MapSet.difference(old_keys, new_keys) |> MapSet.to_list()

    joins = new |> Map.take(join_keys) |> Map.values()
    leaves = old |> Map.take(left_keys) |> Map.values()

    Changes.new(joins, leaves)
  end

  def wire_entries_to_entries(wire_entries, origin) do
    wire_entries
    |> Enum.map(fn
      {partition, key, ref, meta} -> Entry.new(origin, partition, key, meta, ref)
    end)
    |> Enum.reduce(%{}, fn e, acc -> Map.put(acc, e.ref, e) end)
  end

  defp newer?(_stamp, nil), do: true
  defp newer?({:stamp, incarnation_a, _}, {:stamp, incarnation_b, _}) when incarnation_a > incarnation_b, do: true
  defp newer?({:stamp, inc, version_a}, {:stamp, inc, version_b}), do: version_a > version_b
  defp newer?(_, _), do: false

  defp diff_status(
         {:stamp, diff_incarnation, _diff_version} = _diff_stamp,
         diff_base_version,
         {:stamp, current_incarnation, current_version} = _current_mark
       )
       when current_incarnation == diff_incarnation and current_version == diff_base_version,
       do: :applicable

  defp diff_status(diff_stamp, _base, current_mark) do
    if newer?(diff_stamp, current_mark) do
      :behind
    else
      :stale
    end
  end
end
