defmodule Realtime.Presence.Encoder do
  @moduledoc """
  Encodes the state and the diffs of Rollcall as the payloads that a client
  receives: `presence_state` and `presence_diff`.

  Clients such as `realtime-js` expect the payloads of `Phoenix.Presence`. This
  module gives Rollcall output the same shape, so a client does not see which
  library tracks the presence.

  See `Rollcall.state/3` for the entries of a partition and
  `Rollcall.Transport.publish/3` for the diff.
  """

  @typedoc "The presence of one key: the metas of its entries."
  @type presence :: %{metas: [map()]}

  @typedoc "Presences by key."
  @type grouped :: %{Rollcall.key() => presence()}

  @typedoc "The payload of a `presence_diff` event."
  @type diff :: %{joins: grouped(), leaves: grouped()}

  @doc """
  Returns the payload of a `presence_state` event for the entries of a
  partition.
  """
  @spec state([Rollcall.entry()]) :: grouped()
  def state(rollcall_state) do
    map_entries(rollcall_state)
  end

  @doc """
  Returns the payload of a `presence_diff` event for the joins and the leaves
  of a partition.
  """
  @spec diff(Rollcall.partition_diff()) :: diff()
  def diff({joins, leaves}) do
    %{
      joins: map_entries(joins),
      leaves: map_entries(leaves)
    }
  end

  defp map_meta(meta, reference) do
    meta
    |> Map.put(:phx_ref, reference)
    |> replace_prev_ref()
  end

  defp replace_prev_ref(meta) do
    case Map.pop(meta, :rc_prev_ref) do
      {nil, meta} -> meta
      {prev_ref, meta} -> Map.put(meta, :phx_ref_prev, prev_ref)
    end
  end

  defp map_entries(rollcall_state) do
    rollcall_state
    |> Enum.reduce(
      %{},
      fn {reference, key, meta}, acc ->
        meta = map_meta(meta, reference)

        Map.update(acc, key, %{metas: [meta]}, fn entry ->
          %{entry | metas: [meta | entry.metas]}
        end)
      end
    )
  end
end
