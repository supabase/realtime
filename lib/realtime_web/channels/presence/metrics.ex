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
  alias Realtime.FeatureFlags

  @envelope_key :_rt
  @presence_diff "presence_diff"
  @feature_flag "presence_latency_metric"

  @doc """
  Stamps a payload with the current timestamp and node when the track is sampled.

  Sampling is decided per call: the `presence_latency_metric` feature flag must be on for the
  tenant and the call must fall under `PRESENCE_LATENCY_SAMPLE_RATE`. Unsampled calls, and
  anything that is not a map, are returned untouched.
  """
  @spec stamp(term(), String.t()) :: term()
  def stamp(payload, tenant_id) when is_map(payload) do
    if sample?(tenant_id) do
      Map.put(payload, @envelope_key, %{
        ts: System.system_time(:millisecond),
        node: Realtime.Nodes.short_node_id_from_name(node())
      })
    else
      payload
    end
  end

  def stamp(v, _tenant_id), do: v

  @doc false
  @spec sample?(String.t(), float()) :: boolean()
  def sample?(tenant_id, rate \\ sample_rate()) do
    rate > 0 and FeatureFlags.enabled?(@feature_flag, tenant_id) and :rand.uniform() < rate
  end

  defp sample_rate, do: Application.get_env(:realtime, :presence_latency_sample_rate, 0.0)

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
