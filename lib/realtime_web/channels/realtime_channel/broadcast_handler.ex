defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.FeatureFlags
  alias Realtime.Messages
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.TokenBucket
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.RequestMetrics
  alias RealtimeWeb.TenantBroadcaster
  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies

  @type payload :: map | {String.t(), :json | :binary, binary, map()}

  @type ok_reply :: {:reply, :ok | {:ok, map()}, Socket.t()}
  @type error_reply :: {:reply, {:error, %{error: atom()}}, Socket.t()}
  @type noreply :: {:noreply, Socket.t()}

  @type persisted :: {:ok, String.t()} | {:error, atom()}

  @event_type "broadcast"
  @spec handle(payload, Socket.t()) :: {ok_reply() | error_reply() | noreply(), RequestMetrics.outcome()}
  def handle(payload, %{assigns: %{private?: false}} = socket), do: handle(payload, nil, socket)

  @doc """
  Handles an outgoing broadcast for a channel.

  `db_conn` is `nil` for public channels, which don't run write authorization nor persist messages.
  Otherwise must pass the tenant database conn used to run write authorization and persist the message.

  With `ack` a message that is persisted is not replied to here. `Realtime.Messages` sends its result to
  the channel process, which replies with `handle_persisted/3`, so the channel keeps handling messages
  meanwhile. The outcome is then `:deferred`.

  Each persisted message takes a token from the socket's `:persist_bucket`, shared by all its channels.
  If the bucket is empty, the message is delivered but not persisted, and fails with `persistence_rate_limit`.
  """
  @spec handle(payload, pid() | nil, Socket.t()) ::
          {ok_reply() | error_reply() | noreply(), RequestMetrics.outcome() | :deferred}
  def handle(payload, db_conn, %{assigns: %{private?: true}} = socket) do
    with {:ok, persist} <- parse_persist(socket, payload),
         {:ok, socket} <- authorize_write(socket, db_conn, persist),
         socket = increment_rate_counter(socket),
         :ok <- check_payload_size(socket, payload) do
      %{
        assigns: %{
          policies: policies,
          tenant_topic: tenant_topic,
          self_broadcast: self_broadcast,
          ack_broadcast: ack_broadcast,
          tenant: tenant_id,
          authorization_context: %{topic: topic}
        }
      } = socket

      # Broadcast first to prioritize throughput.
      send_message(tenant_id, self_broadcast, tenant_topic, payload)

      result =
        maybe_persist(
          policies: policies,
          db_conn: db_conn,
          tenant_id: tenant_id,
          topic: topic,
          payload: payload,
          ack_broadcast: ack_broadcast,
          persist: persist,
          persist_bucket: socket.private.persist_bucket
        )

      case result do
        {:error, :persistence_rate_limit} ->
          Messages.emit_dropped(tenant_id, :persistence_rate_limit, 1)
          socket |> count_rate_limited() |> maybe_reply_error(:persistence_rate_limit)

        {:error, code} ->
          maybe_reply_error(socket, code)

        {:pending, ref} ->
          {{:noreply, await_persisted(socket, ref)}, :deferred}

        _ ->
          reply_success(socket, result)
      end
    else
      {:error, code, socket} -> maybe_reply_error(socket, code)
    end
  end

  def handle(payload, _db_conn, %{assigns: %{private?: false}} = socket) do
    # The rate counter goes before the `with` because a public broadcast counts even when too large.
    socket = increment_rate_counter(socket)

    with :ok <- check_payload_size(socket, payload) do
      %{
        assigns: %{
          tenant_topic: tenant_topic,
          self_broadcast: self_broadcast,
          tenant: tenant_id
        }
      } = socket

      send_message(tenant_id, self_broadcast, tenant_topic, payload)
      reply_success(socket, :ok)
    else
      {:error, code, socket} -> maybe_reply_error(socket, code)
    end
  end

  @doc """
  Replies with the error `code` when the channel acknowledges broadcasts.

  Returns the outcome with the reply. The outcome is from
  `RequestMetrics.classify_broadcast_error(code)`.
  """
  @spec maybe_reply_error(Socket.t(), atom()) :: {error_reply() | noreply(), RequestMetrics.outcome()}
  def maybe_reply_error(socket, code) do
    outcome = RequestMetrics.classify_broadcast_error(code)
    result = error_reply(socket, code)
    {result, outcome}
  end

  defp error_reply(%{assigns: %{ack_broadcast: true}} = socket, code),
    do: {:reply, {:error, %{error: code}}, socket}

  defp error_reply(socket, _code), do: {:noreply, socket}

  @doc """
  Replies to a broadcast whose `ack` waited for its message to be persisted, and records its outcome.

  `result` is what `Realtime.Messages` sent, or `{:error, :persistence_timeout}` when nothing came within
  `Realtime.Messages.ack_timeout/0`. A result for a broadcast that was already replied to is ignored.
  """
  @spec handle_persisted(reference(), persisted(), Socket.t()) :: noreply()
  def handle_persisted(ref, result, %{assigns: %{tenant: tenant_id}} = socket) do
    pending = Map.get(socket.assigns, :pending_acks, %{})

    case Map.pop(pending, ref) do
      {nil, _pending} ->
        {:noreply, socket}

      {{socket_ref, timer}, pending} ->
        Process.cancel_timer(timer)
        {reply, outcome} = persisted_reply(result)
        Phoenix.Channel.reply(socket_ref, reply)
        RequestMetrics.record(:broadcast, :ws, tenant_id, outcome)
        {:noreply, assign(socket, :pending_acks, pending)}
    end
  end

  @doc """
  Logs how many messages this channel did not persist because its socket was over the cap, since the last
  report. A channel reports at most once per `:drops_report_interval_ms`, like `Realtime.Messages`.
  """
  @spec report_rate_limited(Socket.t()) :: noreply()
  def report_rate_limited(socket) do
    Messages.log_dropped("PersistenceLimitReached", :persistence_rate_limit, socket.assigns.persistence_rate_limited)
    {:noreply, assign(socket, :persistence_rate_limited, 0)}
  end

  defp count_rate_limited(%{assigns: %{persistence_rate_limited: count}} = socket) when count > 0 do
    assign(socket, :persistence_rate_limited, count + 1)
  end

  defp count_rate_limited(socket) do
    Process.send_after(self(), :report_persist_rate_limited, Messages.config()[:drops_report_interval_ms])
    assign(socket, :persistence_rate_limited, 1)
  end

  defp await_persisted(socket, ref) do
    timer = Process.send_after(self(), {:persist_timeout, ref}, Messages.ack_timeout())
    socket_ref = Phoenix.Channel.socket_ref(socket)
    pending = socket.assigns |> Map.get(:pending_acks, %{}) |> Map.put(ref, {socket_ref, timer})
    assign(socket, :pending_acks, pending)
  end

  defp persisted_reply({:ok, id}), do: {{:ok, %{id: id}}, :success}

  defp persisted_reply({:error, code}) do
    {{:error, %{error: code}}, RequestMetrics.classify_broadcast_error(code)}
  end

  @spec reply_success(Socket.t(), :ok) :: {ok_reply() | noreply(), :success}
  defp reply_success(%{assigns: %{ack_broadcast: true}} = socket, _result) do
    {{:reply, :ok, socket}, :success}
  end

  defp reply_success(socket, _result), do: {{:noreply, socket}, :success}

  defp send_message(tenant_id, self_broadcast, tenant_topic, payload) do
    broadcast = build_broadcast(tenant_topic, payload)

    if self_broadcast do
      TenantBroadcaster.pubsub_broadcast(
        tenant_id,
        tenant_topic,
        broadcast,
        RealtimeChannel.MessageDispatcher,
        :broadcast
      )
    else
      TenantBroadcaster.pubsub_broadcast_from(
        tenant_id,
        self(),
        tenant_topic,
        broadcast,
        RealtimeChannel.MessageDispatcher,
        :broadcast
      )
    end
  end

  # No idea why Dialyzer is complaining here
  @dialyzer {:nowarn_function, build_broadcast: 2}

  # Message payload was built by V2 Serializer which was originally UserBroadcastPush
  # We are not using the metadata for anything just yet.
  defp build_broadcast(topic, {user_event, user_payload_encoding, user_payload, _metadata}) do
    %RealtimeWeb.Socket.UserBroadcast{
      topic: topic,
      user_event: user_event,
      user_payload_encoding: user_payload_encoding,
      user_payload: user_payload
    }
  end

  defp build_broadcast(topic, payload) do
    %Phoenix.Socket.Broadcast{topic: topic, event: @event_type, payload: payload}
  end

  # Saves the message when the policy allows it and the sender asked for it.
  #
  # ## Options
  #
  #   * `:policies` - the cached policy answer for this socket
  #   * `:db_conn` - the tenant database connection
  #   * `:tenant_id` - the tenant the message belongs to
  #   * `:topic` - the channel topic, used as the row's topic
  #   * `:payload` - the broadcast frame
  #   * `:ack_broadcast` - when true, returns `{:pending, ref}` and `Realtime.Messages` sends
  #     `{{:persisted, ref}, result}` to this process. When false, enqueues it. When true, a message that
  #     was asked to be saved but the policy denies returns an error
  #   * `:persist` - what the sender asked for, or `nil` to not save it
  #   * `:persist_bucket` - the socket's persisted messages per second, see `RealtimeWeb.UserSocket`
  #
  # All are required.
  @spec maybe_persist(keyword()) :: :ok | {:pending, reference()} | {:error, atom()}
  defp maybe_persist(opts) do
    policies = Keyword.fetch!(opts, :policies)
    persist = Keyword.fetch!(opts, :persist)
    ack_broadcast = Keyword.fetch!(opts, :ack_broadcast)

    cond do
      persist?(policies, persist) ->
        if TokenBucket.take(Keyword.fetch!(opts, :persist_bucket)) == :ok do
          persist(opts)
        else
          {:error, :persistence_rate_limit}
        end

      not is_nil(persist) and ack_broadcast ->
        {:error, :persistence_unauthorized}

      true ->
        :ok
    end
  end

  defp persist(opts) do
    db_conn = Keyword.fetch!(opts, :db_conn)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    topic = Keyword.fetch!(opts, :topic)
    payload = Keyword.fetch!(opts, :payload)
    ack_broadcast = Keyword.fetch!(opts, :ack_broadcast)

    expires_at = opts |> Keyword.fetch!(:persist) |> Map.fetch!(:ttl) |> Messages.expires_at()

    case convert_to_persistable_fields(payload) do
      {:ok, event, event_payload} when ack_broadcast ->
        ref = make_ref()
        persist_opts = [expires_at: expires_at, reply_to: {self(), {:persisted, ref}}]
        Messages.persist(db_conn, tenant_id, topic, event, event_payload, persist_opts)
        {:pending, ref}

      {:ok, event, event_payload} ->
        Messages.persist(db_conn, tenant_id, topic, event, event_payload, expires_at: expires_at)

      {:error, :unsupported_payload} = error ->
        log_error("UnableToPersistMessage", error)
        {:error, :persistence_failed}
    end
  end

  @spec convert_to_persistable_fields(payload) ::
          {:ok, String.t(), Messages.payload()} | {:error, :unsupported_payload}
  # Already in JSON format, use Fragment to skip decode and re-encode
  defp convert_to_persistable_fields({event, :json, user_payload, _metadata}),
    do: {:ok, event, {:json, Jason.Fragment.new(user_payload)}}

  defp convert_to_persistable_fields({event, :binary, user_payload, _metadata}),
    do: {:ok, event, {:binary, user_payload}}

  defp convert_to_persistable_fields(_payload), do: {:error, :unsupported_payload}

  defp increment_rate_counter(%{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{write: false}}}} = socket) do
    socket
  end

  defp increment_rate_counter(%{assigns: %{tenant: tenant_id}} = socket) do
    key = Tenants.events_per_second_key(tenant_id)

    if RateCounter.find(key) == {:error, :not_found} do
      tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)
      RateCounter.get(Tenants.events_per_second_rate(tenant))
    end

    GenCounter.add(key)
    socket
  end

  @spec parse_persist(Socket.t(), payload) :: {:ok, Messages.persist()} | {:error, atom(), Socket.t()}
  defp parse_persist(%{assigns: %{tenant: tenant_id}} = socket, payload) do
    case payload |> persist_option() |> Messages.parse_persist() do
      {:ok, persist} ->
        {:ok, if(FeatureFlags.enabled?("broadcast_persistence", tenant_id), do: persist)}

      {:error, :invalid_ttl} ->
        log_error(
          "PersistenceInvalidTtl",
          "persist ttl must be a positive integer of seconds from 1 to #{Messages.max_ttl_seconds()}"
        )

        {:error, :persistence_invalid_ttl, socket}
    end
  end

  @spec authorize_write(Socket.t(), pid() | nil, Messages.persist()) ::
          {:ok, Socket.t()} | {:error, atom(), Socket.t()}
  defp authorize_write(socket, db_conn, persist) do
    %{
      assigns: %{
        policies: policies,
        authorization_context: authorization_context
      }
    } = socket

    case run_authorization_check(policies || %Policies{}, db_conn, authorization_context, persist) do
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} ->
        {:ok, assign(socket, :policies, policies)}

      {:ok, policies} ->
        {:error, :unauthorized, assign(socket, :policies, policies)}

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)
        {:error, :rls_policy_error, socket}

      {:error, :query_canceled, error} ->
        log_error("QueryCanceled", error)
        {:error, :query_canceled, socket}

      {:error, :missing_partition} ->
        log_error("MissingPartition", "Realtime was unable to find the expected messages partition")
        {:error, :missing_partition, socket}

      {:error, :tenant_database_unavailable} ->
        log_error("UnableToConnectToProject", "Realtime was unable to connect to the project database")
        {:error, :unable_to_connect_to_project, socket}

      {:error, :increase_connection_pool} ->
        {:error, :increase_connection_pool, socket}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:error, :unable_to_set_policies, socket}
    end
  end

  @doc false
  # Which write policies still need a probe.
  #
  # `write` and `persist` are cached per socket and tri-state: `nil` means not checked yet. Intent
  # is per message and never cached, so a message that does not ask to persist never probes the
  # `persistence` policy, and a message that does ask probes it once and reuses the answer.
  @spec extensions_to_probe(Policies.t(), Messages.persist()) :: [Authorization.extension()]
  def extensions_to_probe(%Policies{broadcast: %BroadcastPolicies{write: write, persist: allowed}}, persist) do
    [
      if(is_nil(write), do: :broadcast),
      if(not is_nil(persist) and is_nil(allowed), do: :persistence)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  # Whether this message should be saved, given what the sender asked for and the cached policy answer.
  @spec persist?(Policies.t(), Messages.persist()) :: boolean()
  def persist?(%Policies{broadcast: %BroadcastPolicies{persist: true}}, persist) when is_map(persist), do: true
  def persist?(_policies, _persist), do: false

  @doc false
  # What the sender asked for, read from the frame metadata rather than the payload. The map form of
  # a broadcast is forwarded to subscribers as-is, so a control key there would leak.
  @spec persist_option(payload) :: term()
  def persist_option({_event, _encoding, _payload, metadata}) when is_map(metadata), do: metadata["persist"]
  def persist_option(_payload), do: nil

  defp run_authorization_check(policies, db_conn, authorization_context, persist) do
    case extensions_to_probe(policies, persist) do
      [] -> {:ok, policies}
      extensions -> Authorization.get_write_authorizations(policies, db_conn, authorization_context, extensions)
    end
  end

  @spec check_payload_size(Socket.t(), payload) :: :ok | {:error, :payload_size_exceeded, Socket.t()}
  defp check_payload_size(%{assigns: %{tenant: tenant_id}} = socket, payload) do
    case Tenants.validate_payload_size(tenant_id, payload) do
      :ok -> :ok
      {:error, :payload_size_exceeded} -> {:error, :payload_size_exceeded, socket}
    end
  end
end
