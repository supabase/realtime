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
  @latency_event [:realtime, :presence, :notify, :latency]
  @discarded_event [:realtime, :presence, :notify, :discarded]
  # Phoenix.Tracker's down detection window (broadcast_period × max_silent_periods × 2). A join
  # older than this cannot be a live delivery; it is a replay from transfer_ack or netsplit recovery.
  @stale_after_ms 30_000

  @type context :: %{
          tenant: String.t() | nil,
          path: :fastlane | :channel,
          implementation: atom(),
          now: integer(),
          node: String.t()
        }

  defmodule Envelope do
    @moduledoc """
    Provides a struct for repesenting a resolved metrics envelope.

    This includes an :action value that identifies whether the action was a track or an update.
    """
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
  Builds the context `record/2` measures against, once per dispatched diff.

  Fixes `now` and this node's id so every subscriber of the same diff is measured against the
  same instant.
  """
  @spec context(String.t() | nil, :fastlane | :channel) :: context()
  def context(tenant_id, path) do
    %{
      tenant: tenant_id,
      path: path,
      implementation: :phoenix,
      now: System.system_time(:millisecond),
      node: Realtime.Nodes.short_node_id_from_name(node())
    }
  end

  @doc """
  Records one latency observation per envelope, for one notified subscriber.

  A negative latency (clock skew between nodes) or one past the stale bound (a replayed join) is
  counted as discarded instead of recorded.
  """
  @spec record([Envelope.t()], context()) :: :ok
  def record([], _context), do: :ok

  def record(envelopes, context) do
    Enum.each(envelopes, &record_one(&1, context))
  end

  defp record_one(%Envelope{ts: ts, node: node, action: action}, context) do
    latency = context.now - ts

    metadata = %{
      tenant: context.tenant,
      action: action,
      origin: if(node == context.node, do: :local, else: :remote),
      path: context.path,
      implementation: context.implementation
    }

    cond do
      latency < 0 -> :telemetry.execute(@discarded_event, %{count: 1}, Map.put(metadata, :reason, :negative))
      latency > @stale_after_ms -> :telemetry.execute(@discarded_event, %{count: 1}, Map.put(metadata, :reason, :stale))
      true -> :telemetry.execute(@latency_event, %{latency: latency}, metadata)
    end
  end

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
