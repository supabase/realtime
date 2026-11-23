defmodule RealtimeWeb.RealtimeChannel.FastlaneSender do
  @moduledoc """
  `Phoenix.PubSub.Sender` for channel fastlane subscriptions.

  Inspired by Phoenix.Channel.Server.dispatch/3. Subscribe with `sender/1` and broadcast with the default
  `Phoenix.PubSub` dispatcher, which calls `send/4` and `finalize/1`.
  """

  @behaviour Phoenix.PubSub.Sender

  require Logger
  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.Socket.UserBroadcast

  def fastlane_metadata(
        fastlane_pid,
        serializer,
        topic,
        log_level,
        tenant_id,
        replayed_message_ids \\ MapSet.new(),
        presence_read? \\ true,
        broadcast_read? \\ true
      ) do
    {:rc_fastlane, fastlane_pid, serializer, topic, log_level, tenant_id, replayed_message_ids, presence_read?,
     broadcast_read?}
  end

  @presence_diff "presence_diff"
  @broadcast "broadcast"

  @doc """
  Returns the `:sender` subscription option that delivers through this module.

  `metadata` comes from `fastlane_metadata/8`.
  """
  @spec sender(tuple()) :: {module(), tuple()}
  def sender(metadata), do: {__MODULE__, metadata}

  @doc """
  Delivers one message to one fastlane subscription.

  `Phoenix.PubSub` calls this function once for each subscription in a Registry partition. The first call
  gets `nil` as `state` and builds the state from the message. Later calls reuse it, so the message is
  unwrapped, encoded and checked against the rate counter once per partition, not once per subscriber.

  Non presence messages delivered through fastlane are counted in bulk against the tenant's events
  rate counter in `finalize/1`. Channel processes are only messaged (`:check_rate_counter`) when that
  counter has triggered its limit, so they can shut down, or when it is not running, so they can restart it.

  fastlane_pid is the actual socket transport pid
  """
  @impl Phoenix.PubSub.Sender
  def send(pid, metadata, message, nil), do: send(pid, metadata, message, init_state(message, metadata))

  def send(pid, metadata, _message, %{mode: :presence} = state), do: send_presence(pid, metadata, state)

  def send(pid, metadata, _message, %{mode: :events} = state), do: send_event(pid, metadata, state)

  def send(pid, _metadata, message, %{mode: :passthrough} = state) do
    Kernel.send(pid, message)
    state
  end

  @doc """
  Adds the fastlane deliveries of one Registry partition to the tenant's rate counters.
  """
  @impl Phoenix.PubSub.Sender
  def finalize(%{mode: :presence, tenant_id: tenant_id, msg: msg, count: count}),
    do: increment_presence_counter(tenant_id, msg.event, count)

  def finalize(%{mode: :events, tenant_id: tenant_id, count: count}), do: increment_events_counter(tenant_id, count)

  def finalize(_state), do: :ok

  # Broadcast messages are tagged with their tenant_id by RealtimeWeb.TenantBroadcaster so the
  # receiving node can attribute the fan-out before delivery. Strip the tag here so every
  # downstream clause (and the client) only ever sees the underlying struct.
  defp init_state({:tb, _tenant_id, %Broadcast{event: @presence_diff} = msg}, metadata),
    do: init_state(msg, metadata)

  defp init_state({:tb, tenant_id, msg}, _metadata), do: events_state(msg, tenant_id)

  defp init_state(%Broadcast{event: @presence_diff} = original_msg, metadata) do
    {msg, envelopes} = Realtime.Presence.Metrics.strip_diff(original_msg)
    tenant_id = tenant_id(metadata)

    %{
      mode: :presence,
      msg: msg,
      original_msg: original_msg,
      envelopes: envelopes,
      metrics_context: Realtime.Presence.Metrics.context(tenant_id, :fastlane),
      tenant_id: tenant_id,
      cache: %{},
      count: 0
    }
  end

  defp init_state(%Broadcast{} = msg, metadata), do: events_state(msg, tenant_id(metadata))
  defp init_state(%UserBroadcast{} = msg, metadata), do: events_state(msg, tenant_id(metadata))

  # Any other message reaches the channel process unchanged, as it would without a sender.
  defp init_state(_message, _metadata), do: %{mode: :passthrough}

  defp events_state(msg, tenant_id) do
    %{
      mode: :events,
      msg: msg,
      tenant_id: tenant_id,
      message_id: message_id(msg),
      broadcast?: broadcast?(msg),
      check_rate_counter?: check_rate_counter?(tenant_id),
      cache: %{},
      count: 0
    }
  end

  # Subscriber is denied presence.read: withhold the presence_diff. Mirrors the
  # can_read_presence?/1 gate on the presence_state push.
  defp send_presence(_pid, {:rc_fastlane, _, _, _, _, _, _, false, _}, state), do: state

  # presence.read not yet authorized (presence was not enabled at join): route to the channel
  # process so it can consult presence.read at delivery time. Wrapped in a
  # tuple so it is handled by RealtimeChannel.handle_info rather than intercepted and pushed by
  # Phoenix.Channel.Server's built-in %Broadcast{} handling.
  defp send_presence(pid, {:rc_fastlane, _, _, _, _, _, _, nil, _}, state) do
    Kernel.send(pid, {:authorize_presence_diff, state.original_msg})
    state
  end

  defp send_presence(
         _pid,
         {:rc_fastlane, fastlane_pid, serializer, join_topic, log_level, tenant_id, _replayed_message_ids, true,
          _broadcast_read?},
         state
       ) do
    maybe_log(log_level, join_topic, state.msg, tenant_id)

    cache = fastlane_dispatch(state.msg, fastlane_pid, serializer, join_topic, state.cache, tenant_id, log_level)

    Realtime.Presence.Metrics.record(state.envelopes, state.metrics_context)

    %{state | cache: cache, count: state.count + 1}
  end

  defp send_event(
         pid,
         {:rc_fastlane, fastlane_pid, serializer, join_topic, log_level, tenant_id, replayed_message_ids,
          _presence_read?, broadcast_read?},
         state
       ) do
    if (state.broadcast? and broadcast_read? != true) or already_replayed?(state.message_id, replayed_message_ids) do
      state
    else
      if state.check_rate_counter?, do: Kernel.send(pid, :check_rate_counter)

      maybe_log(log_level, join_topic, state.msg, tenant_id)

      cache = fastlane_dispatch(state.msg, fastlane_pid, serializer, join_topic, state.cache, tenant_id, log_level)

      %{state | cache: cache, count: state.count + 1}
    end
  end

  defp broadcast?(%UserBroadcast{}), do: true
  defp broadcast?(%Broadcast{event: @broadcast}), do: true
  defp broadcast?(_msg), do: false

  defp maybe_log(:info, join_topic, msg, tenant_id) when is_struct(msg) do
    log = "Received message on #{join_topic} with payload: #{inspect(msg, pretty: true)}"
    Logger.info(log, external_id: tenant_id, project: tenant_id)
  end

  defp maybe_log(:info, join_topic, msg, tenant_id) when is_binary(msg) do
    log = "Received message on #{join_topic}. #{msg}"
    Logger.info(log, external_id: tenant_id, project: tenant_id)
  end

  defp maybe_log(_level, _join_topic, _msg, _tenant_id), do: :ok

  defp fastlane_dispatch(msg, fastlane_pid, serializer, join_topic, encoded_cache, tenant_id, log_level) do
    case encoded_cache do
      %{{^serializer, ^join_topic} => {:ok, encoded_msg}} ->
        send(fastlane_pid, encoded_msg)
        encoded_cache

      %{{^serializer, ^join_topic} => {:error, _reason}} ->
        # We do nothing at this stage. It has been already logged depending on the log level
        encoded_cache

      %{} ->
        # Use the original topic that was joined without the external_id
        msg = %{msg | topic: join_topic}

        result =
          case fastlane!(serializer, msg) do
            {:ok, encoded_msg} ->
              send(fastlane_pid, encoded_msg)
              {:ok, encoded_msg}

            {:error, reason} ->
              maybe_log(log_level, join_topic, reason, tenant_id)
              {:error, reason}
          end

        Map.put(encoded_cache, {serializer, join_topic}, result)
    end
  end

  # We have to convert because V1 does not know how to process UserBroadcast
  defp fastlane!(Phoenix.Socket.V1.JSONSerializer = serializer, %UserBroadcast{} = msg) do
    with {:ok, msg} <- UserBroadcast.convert_to_json_broadcast(msg) do
      encode(serializer, msg)
    end
  end

  defp fastlane!(serializer, msg), do: encode(serializer, msg)

  # A serializer raises on a message it can't encode (e.g. an event over its 255-byte limit).
  # Contain it so one message is skipped instead of crashing the shared process doing the dispatch.
  defp encode(serializer, msg) do
    case serializer.fastlane!(msg) do
      # Flatten so every subscriber shares one binary instead of getting its own copy of the iodata.
      {:socket_push, opcode, payload} -> {:ok, {:socket_push, opcode, IO.iodata_to_binary(payload)}}
      encoded -> {:ok, encoded}
    end
  rescue
    error -> {:error, error}
  end

  defp tenant_id({:rc_fastlane, _, _, _, _, tenant_id, _, _, _}), do: tenant_id

  defp check_rate_counter?(tenant_id) when is_binary(tenant_id) do
    case tenant_id |> Realtime.Tenants.events_per_second_key() |> Realtime.RateCounter.find() do
      {:ok, %{limit: %{triggered: true}}} -> true
      {:ok, _} -> false
      {:error, :not_found} -> true
    end
  end

  defp check_rate_counter?(_tenant_id), do: false

  defp increment_events_counter(tenant_id, count) when is_binary(tenant_id) and count > 0 do
    tenant_id
    |> Realtime.Tenants.events_per_second_key()
    |> Realtime.GenCounter.add(count)
  end

  defp increment_events_counter(_tenant_id, _count), do: :ok

  defp increment_presence_counter(tenant_id, "presence_diff", count) when is_binary(tenant_id) do
    tenant_id
    |> Realtime.Tenants.presence_events_per_second_key()
    |> Realtime.GenCounter.add(count)
  end

  defp increment_presence_counter(_tenant_id, _event, _count), do: :ok

  defp message_id(%UserBroadcast{metadata: %{"id" => id}}), do: id
  defp message_id(%Broadcast{payload: %{"meta" => %{"id" => id}}}), do: id
  defp message_id(_), do: nil

  defp already_replayed?(nil, _replayed_message_ids), do: false
  defp already_replayed?(message_id, replayed_message_ids), do: MapSet.member?(replayed_message_ids, message_id)
end
