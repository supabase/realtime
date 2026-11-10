defmodule Realtime.Presence.Metrics do
  @moduledoc """
  Handles metrics related to Presence performance.

  A sampled payload carries an internal envelope under `@envelope_key` in its tracker meta: when it
  was stamped, on which node and for which implementation. The envelope travels with the meta through Tracker
  replication and is read back where the resulting `presence_diff` is handed to subscribers. It is
  never meant to reach a client, so every path that publishes metas should strip the envelope using 
  one of the `strip_*` functions.

  This module also includes an `Envelope` struct that's returned by `strip_diffs`. This struct has
  the action resolved to `:track` or `:update` based on the contents of the meta.
  """
  alias Realtime.Presence
  alias Phoenix.Socket.Broadcast
  alias Realtime.FeatureFlags

  @envelope_key :_rt
  @presence_diff "presence_diff"
  @feature_flag "presence_latency_metric"
  @latency_event [:realtime, :presence, :notify, :latency]
  @discarded_event [:realtime, :presence, :notify, :discarded]
  @join_latency_event [:realtime, :presence, :join, :latency]
  @track_duration_event [:realtime, :presence, :track, :duration]
  # Phoenix.Tracker's down detection window (broadcast_period × max_silent_periods × 2). A join
  # older than this cannot be a live delivery; it is a replay from transfer_ack or netsplit recovery.
  @stale_after_ms 30_000

  @type context :: %{
          tenant: String.t() | nil,
          path: :fastlane | :channel | :transport,
          now: integer(),
          node: String.t()
        }

  defmodule Envelope do
    @moduledoc """
    Provides a struct for repesenting a resolved metrics envelope.

    This includes an :action value that identifies whether the action was a track or an update.
    It also includes the :implementation that tracked the entry.
    """
    @phx_update_key :phx_ref_prev

    @type t :: %__MODULE__{
            ts: non_neg_integer(),
            node: String.t() | nil,
            action: :track | :update,
            implementation: Presence.implementation()
          }

    defstruct [:ts, :node, :action, implementation: :phoenix]

    @doc """
    Builds the envelope from the stamp and the meta that carries it.

    A stamp without an implementation comes from a node that tracks in Phoenix only. The envelope
    gets `:phoenix` for it.
    """
    @spec new(map(), map()) :: t()
    def new(stamp, meta) do
      %__MODULE__{
        ts: Map.get(stamp, :ts, 0),
        node: Map.get(stamp, :node),
        implementation: Map.get(stamp, :impl, :phoenix),
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

  `implementation` is the backend that tracks the payload. The envelope carries it, so the latency
  of a diff gets the tag of the backend that made the diff, even when a flag changes in between.
  """
  @spec stamp(term(), String.t(), Presence.implementation()) :: term()
  def stamp(payload, tenant_id, implementation) when is_map(payload) do
    if sample?(tenant_id) do
      Map.put_new(payload, @envelope_key, %{
        ts: System.system_time(:millisecond),
        node: Realtime.Nodes.short_node_id_from_name(node()),
        impl: implementation
      })
    else
      payload
    end
  end

  def stamp(v, _tenant_id, _implementation), do: v

  @doc false
  @spec sample?(String.t(), float()) :: boolean()
  def sample?(tenant_id, rate \\ sample_rate()) do
    rate > 0 and FeatureFlags.enabled?(@feature_flag, tenant_id) and :rand.uniform() < rate
  end

  defp sample_rate, do: Application.get_env(:realtime, :presence_latency_sample_rate, 0.0)

  @doc """
  Strips and returns the envelope from every join and leave meta in a `presence_diff` broadcast.

  Returns {msg, envelopes}, where msg has all the tracking timestamps removed and envelopes is 
  a list of all the timestamps extracted out of the meta's and resolved into `Realtime.Presence.Metrics.Envelope`
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

  `path` is `:fastlane` or `:channel` for a diff that the dispatcher delivers to subscribers. It is
  `:transport` for a diff that the Rollcall transport measures in the shadow mode. That path has
  one observation for each diff, not for each subscriber.
  """
  @spec context(String.t() | nil, :fastlane | :channel | :transport) :: context()
  def context(tenant_id, path) do
    %{
      tenant: tenant_id,
      path: path,
      now: System.system_time(:millisecond),
      node: Realtime.Nodes.short_node_id_from_name(node())
    }
  end

  @doc """
  Records one latency observation per envelope, for one notified subscriber.

  Each observation takes the `implementation` tag from its envelope. The envelope has no tag
  when a node that tracks in Phoenix only stamped it. The tag is `:phoenix` then.

  A negative latency (clock skew between nodes) or one past the stale bound (a replayed join) is
  counted as discarded instead of recorded.
  """
  @spec record([Envelope.t()], context()) :: :ok
  def record([], _context), do: :ok

  def record(envelopes, context) do
    Enum.each(envelopes, &record_one(&1, context))
  end

  defp record_one(%Envelope{ts: ts, node: node, action: action, implementation: implementation}, context) do
    latency = context.now - ts

    metadata = %{
      tenant: context.tenant,
      action: action,
      origin: if(node == context.node, do: :local, else: :remote),
      path: context.path,
      implementation: implementation
    }

    cond do
      latency < 0 -> :telemetry.execute(@discarded_event, %{count: 1}, Map.put(metadata, :reason, :negative))
      latency > @stale_after_ms -> :telemetry.execute(@discarded_event, %{count: 1}, Map.put(metadata, :reason, :stale))
      true -> :telemetry.execute(@latency_event, %{latency: latency}, metadata)
    end
  end

  @doc """
  Records the latency from a client's channel join to its first `presence_state` push.

  `tracker_state` is `:warm` when the local Tracker shard already held state for this topic
  before this join, `:cold` when it was empty. Under today's full-gossip replication, `:cold`
  is just an empty topic — there's no node that has the data but didn't get it yet.

  The `implementation` tag is `Realtime.Presence.implementation_tag/1`: `:rollcall` in the Rollcall
  mode and `:phoenix` in the other modes. The shadow mode has no Rollcall observation.
  """
  @spec record_join(integer(), String.t(), :warm | :cold) :: :ok
  def record_join(started_at, tenant_id, tracker_state) do
    latency = System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    :telemetry.execute(@join_latency_event, %{latency: latency}, %{
      tenant: tenant_id,
      state: tracker_state,
      implementation: Presence.implementation_tag(tenant_id)
    })
  end

  @typedoc "The tracker call that produced a result."
  @type action :: :track | :update

  @doc """
  Times a client's call into the presence tracker and emits `[:realtime, :presence, :track, :duration]`.

  `fun` makes the tracker calls and returns `{:ok, action, ref}` or `{:error, action, reason}`, where
  `action` is `:track` or `:update`: the call that produced the result. The duration covers
  everything `fun` does, so a track that falls back to an update is one observation tagged `:update`.

  Returns the result of `fun`. If `fun` exits, the exit is recorded under its reason and then
  re-raised unchanged. An exit has no action to read, so it is recorded as `:track`, the call every
  request starts with.

  `implementation` is the backend that `fun` calls. The event carries it as a tag.
  """
  @spec measure_tracker_call(
          (-> {:ok, action(), String.t()} | {:error, action(), term()}),
          Presence.implementation()
        ) :: {:ok, action(), String.t()} | {:error, action(), term()}
  def measure_tracker_call(fun, implementation \\ :phoenix) do
    {duration, result} =
      :timer.tc(
        fn ->
          try do
            fun.()
          catch
            :exit, reason -> {:exit, :track, reason}
          end
        end,
        :millisecond
      )

    {outcome, action, reason} = classify(result)

    :telemetry.execute(@track_duration_event, %{duration: duration}, %{
      action: action,
      result: outcome,
      reason: reason,
      implementation: implementation
    })

    case result do
      {:exit, _, exit_reason} -> exit(exit_reason)
      result -> result
    end
  end

  defp classify({:ok, action, _}), do: {:ok, action, :none}
  defp classify({:error, action, reason}) when is_atom(reason), do: {:error, action, reason}
  defp classify({:error, action, _}), do: {:error, action, :other}
  defp classify({:exit, action, {:timeout, _}}), do: {:exit, action, :timeout}
  defp classify({:exit, action, {:noproc, _}}), do: {:exit, action, :noproc}
  defp classify({:exit, action, _}), do: {:exit, action, :other}

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
