defmodule RealtimeWeb.Presence.Metrics do
  @moduledoc """
  Handles metrics related to Presence performance.

  A sampled payload carries an internal envelope under `@envelope_key` in its tracker meta: when it
  was stamped and on which node. The envelope travels with the meta through Tracker
  replication and is read back where the resulting `presence_diff` is handed to subscribers. It is
  never meant to reach a client, so every path that publishes metas should strip the envelope using 
  one of the `strip_*` functions.

  This module also includes an `Envelope` struct that's returned by `strip_diffs`. This struct has
  the action resolved to `:track` or `:update` based on the contents of the meta.
  """
  alias Phoenix.Socket.Broadcast
  alias Realtime.FeatureFlags

  @envelope_key :_rt
  @presence_diff "presence_diff"
  @feature_flag "presence_latency_metric"

  defmodule Envelope do
    @phx_update_key :phx_ref_prev

    @type t :: %__MODULE__{ts: non_neg_integer(), node: String.t() | nil, action: :track | :update}

    defstruct [:ts, :node, :action]

    def new(stamp, meta) do
      %__MODULE__{
        ts: Map.get(stamp, :ts, 0),
        node: Map.get(stamp, :node),
        action:
          if Map.has_key?(meta, @phx_update_key) do
            :update
          else
            :track
          end
      }
    end
  end

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
  Strips and returns the envelope from every join and leave meta in a `presence_diff` broadcast.

  Returns {msg, envelopes}, where msg has all the tracking timestamps removed and envelopes is 
  a list of all the timestamps extracted out of the meta's and resolved into `RealtimeWeb.Presence.Metrics.Envelope`
  structs.

  Any other broadcast is returned untouched.
  """
  @spec strip_diff(Broadcast.t()) :: {Broadcast.t(), [Envelope.t()]}
  def strip_diff(%Broadcast{event: @presence_diff, payload: payload} = msg) do
    {join_envelopes, payload} = Map.get_and_update(payload, :joins, &get_and_strip_envelopes/1)
    {_leave_envelopes, payload} = Map.get_and_update(payload, :leaves, &get_and_strip_envelopes/1)

    join_envelopes = join_envelopes || []

    {%{msg | payload: payload}, join_envelopes}
  end

  def strip_diff(msg), do: {msg, []}

  @doc """
  Strips the envelope from every meta in a grouped presence list.

  This is the shape pushed to a client as `presence_state`.
  """
  @spec strip_state(map()) :: map()
  def strip_state(presences) when is_map(presences) do
    {_envelopes, striped_presences} = get_and_strip_envelopes(presences)

    striped_presences
  end

  # Takes the grouped presences shape, `%{key => %{metas: [meta, ...]}}`, as found under a diff's
  # :joins / :leaves and in presence_state. Returns {envelopes, entries} with every meta stripped.
  defp get_and_strip_envelopes(nil), do: :pop

  defp get_and_strip_envelopes(entries) do
    Enum.flat_map_reduce(entries, %{}, fn
      {key, value}, acc ->
        case Map.fetch(value, :metas) do
          :error ->
            {[], Map.put(acc, key, value)}

          {:ok, metas} ->
            {new_metas, envelopes} = extract_envelopes(metas)
            {envelopes, Map.put(acc, key, Map.put(value, :metas, new_metas))}
        end
    end)
  end

  # Takes one key's metas, `[%{"user" => ..., :phx_ref => ..., :_rt => %{ts, node}}, ...]`, and
  # returns {metas, envelopes}: the metas in order without :_rt, plus an Envelope per stamped one.
  defp extract_envelopes(metas) do
    Enum.map_reduce(metas, [], fn
      meta, envelopes ->
        case Map.pop(meta, @envelope_key) do
          {nil, meta} -> {meta, envelopes}
          {stamp, meta} -> {meta, [Envelope.new(stamp, meta) | envelopes]}
        end
    end)
  end
end
