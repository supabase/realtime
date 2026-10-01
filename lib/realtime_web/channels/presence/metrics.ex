defmodule RealtimeWeb.Presence.Metrics do
  @moduledoc """
  Handles metrics related to Presence performance.

  A sampled payload carries an internal envelope under `@envelope_key` in its tracker meta: when it
  was stamped and on which node. The envelope travels with the meta through Tracker
  replication and is read back where the resulting `presence_diff` is handed to subscribers. It is
  never meant to reach a client, so every path that publishes metas should strip the envelope using 
  one of the `strip_*` functions.
  """
  alias Phoenix.Socket.Broadcast

  @envelope_key :_rt
  @presence_diff "presence_diff"

  @doc """
  Stamps a payload with the current timestamp and node.

  This can be used for timing metrics later in the lifecycle.
  """
  @spec stamp(term()) :: term()
  def stamp(payload) when is_map(payload) do
    Map.put(payload, @envelope_key, %{
      ts: System.system_time(:millisecond),
      node: Realtime.Nodes.short_node_id_from_name(node())
    })
  end

  def stamp(v), do: v

  @doc """
  Strips the envelope from every join and leave meta in a `presence_diff` broadcast.

  Any other broadcast is returned untouched.
  """
  @spec strip_diff(Broadcast.t()) :: Broadcast.t()
  def strip_diff(%Broadcast{event: @presence_diff, payload: payload} = msg) do
    payload =
      payload
      |> Map.replace_lazy(:joins, &strip_entries/1)
      |> Map.replace_lazy(:leaves, &strip_entries/1)

    %{msg | payload: payload}
  end

  def strip_diff(msg), do: msg

  @doc """
  Strips the envelope from every meta in a grouped presence list.

  This is the shape pushed to a client as `presence_state`.
  """
  @spec strip_state(map()) :: map()
  def strip_state(presences) when is_map(presences), do: strip_entries(presences)

  defp strip_entries(entries) do
    Map.new(entries, fn {key, entry} -> {key, Map.update(entry, :metas, [], &strip_metas/1)} end)
  end

  defp strip_metas(metas), do: Enum.map(metas, &Map.delete(&1, @envelope_key))
end
