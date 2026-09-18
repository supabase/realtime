defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.FeatureFlags
  alias Realtime.Messages
  alias Realtime.Tenants
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.TenantBroadcaster
  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies

  @type payload :: map | {String.t(), :json | :binary, binary, map()}

  @event_type "broadcast"
  @spec handle(payload, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(payload, %{assigns: %{private?: false}} = socket), do: handle(payload, nil, socket)

  @doc """
  Handles an outgoing broadcast for a channel.

  `db_conn` is `nil` for public channels, which don't run write authorization nor persist messages.
  Otherwise must pass the tenant database conn used to run write authorization and persist the message.
  """
  @spec handle(payload, pid() | nil, Socket.t()) ::
          {:reply, :ok | {:ok, map()} | {:error, any()}, Socket.t()} | {:noreply, Socket.t()}
  def handle(payload, db_conn, %{assigns: %{private?: true}} = socket) do
    %{
      assigns: %{
        self_broadcast: self_broadcast,
        tenant_topic: tenant_topic,
        authorization_context: authorization_context,
        policies: policies,
        tenant: tenant_id
      }
    } = socket

    persist_intent = persist_intent(payload) and FeatureFlags.enabled?("broadcast_persistence", tenant_id)

    case run_authorization_check(policies || %Policies{}, db_conn, authorization_context, persist_intent) do
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} ->
        socket =
          socket
          |> assign(:policies, policies)
          |> increment_rate_counter()

        %{ack_broadcast: ack_broadcast} = socket.assigns

        res =
          case Tenants.validate_payload_size(tenant_id, payload) do
            # Broadcast first to prioritize throughput.
            :ok ->
              send_message(tenant_id, self_broadcast, tenant_topic, payload)
              # TODO: hard limits and buffering based on ack
              maybe_persist(
                policies,
                persist_intent,
                db_conn,
                tenant_id,
                authorization_context.topic,
                payload,
                ack_broadcast
              )

            {:error, error} ->
              {:error, error}
          end

        cond do
          ack_broadcast && match?({:error, :payload_size_exceeded}, res) ->
            {:reply, {:error, :payload_size_exceeded}, socket}

          ack_broadcast && match?({:ok, _}, res) ->
            {:reply, res, socket}

          ack_broadcast ->
            {:reply, :ok, socket}

          true ->
            {:noreply, socket}
        end

      {:ok, policies} ->
        {:noreply, assign(socket, :policies, policies)}

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)
        {:noreply, socket}

      {:error, :query_canceled, error} ->
        log_error("QueryCanceled", error)
        {:noreply, socket}

      {:error, :missing_partition} ->
        log_error("MissingPartition", "Realtime was unable to find the expected messages partition")
        {:noreply, socket}

      {:error, :tenant_database_unavailable} ->
        log_error("UnableToConnectToProject", "Realtime was unable to connect to the project database")
        {:noreply, socket}

      {:error, :increase_connection_pool} ->
        {:noreply, socket}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:noreply, socket}
    end
  end

  def handle(payload, _db_conn, %{assigns: %{private?: false}} = socket) do
    %{
      assigns: %{
        tenant_topic: tenant_topic,
        self_broadcast: self_broadcast,
        ack_broadcast: ack_broadcast,
        tenant: tenant_id
      }
    } = socket

    socket = increment_rate_counter(socket)

    res =
      case Tenants.validate_payload_size(tenant_id, payload) do
        :ok -> send_message(tenant_id, self_broadcast, tenant_topic, payload)
        error -> error
      end

    cond do
      ack_broadcast && match?({:error, :payload_size_exceeded}, res) ->
        {:reply, {:error, :payload_size_exceeded}, socket}

      ack_broadcast ->
        {:reply, :ok, socket}

      true ->
        {:noreply, socket}
    end
  end

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

  @spec maybe_persist(
          Policies.t(),
          persist_intent :: boolean(),
          pid(),
          String.t(),
          String.t(),
          payload,
          ack_broadcast :: boolean()
        ) :: :ok | {:ok, map()}
  defp maybe_persist(policies, persist_intent, db_conn, tenant_id, topic, payload, ack_broadcast) do
    if persist?(policies, persist_intent) do
      if ack_broadcast do
        persist(db_conn, tenant_id, topic, payload)
      else
        Task.Supervisor.start_child(Realtime.TaskSupervisor, fn ->
          persist(db_conn, tenant_id, topic, payload)
        end)

        :ok
      end
    else
      :ok
    end
  end

  defp persist(db_conn, tenant_id, topic, payload) do
    with {:ok, event, event_payload} <- convert_to_persistable_fields(payload),
         {:ok, id} <- Messages.persist(db_conn, tenant_id, topic, event, event_payload) do
      {:ok, %{id: id}}
    else
      error ->
        log_error("UnableToPersistMessage", error)
        :ok
    end
  end

  @spec convert_to_persistable_fields(payload) ::
          {:ok, String.t(), map() | binary()} | {:error, :unsupported_payload}
  defp convert_to_persistable_fields(%{"event" => event, "payload" => payload}), do: {:ok, event, payload}

  # Already in JSON format, use Fragment to skip decode and re-encode
  defp convert_to_persistable_fields({event, :json, user_payload, _metadata}),
    do: {:ok, event, Jason.Fragment.new(user_payload)}

  defp convert_to_persistable_fields({event, :binary, user_payload, _metadata}), do: {:ok, event, user_payload}

  defp convert_to_persistable_fields(_payload), do: {:error, :unsupported_payload}

  defp increment_rate_counter(%{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{write: false}}}} = socket) do
    socket
  end

  defp increment_rate_counter(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    socket
  end

  @doc false
  # Which write policies still need a probe.
  #
  # `write` and `persist` are cached per socket and tri-state: `nil` means not checked yet. Intent
  # is per message and never cached, so a message that does not ask to persist never probes the
  # `persistence` policy, and a message that does ask probes it once and reuses the answer.
  @spec extensions_to_probe(Policies.t(), persist_intent :: boolean()) :: [Authorization.extension()]
  def extensions_to_probe(%Policies{broadcast: %BroadcastPolicies{write: write, persist: persist}}, persist_intent) do
    [
      if(is_nil(write), do: :broadcast),
      if(persist_intent and is_nil(persist), do: :persistence)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  # Whether this message should be written, given per-message intent and the cached policy answer.
  @spec persist?(Policies.t(), persist_intent :: boolean()) :: boolean()
  def persist?(%Policies{broadcast: %BroadcastPolicies{persist: true}}, true), do: true
  def persist?(_policies, _persist_intent), do: false

  @doc false
  # Per-message persistence intent, read from the frame metadata rather than the payload. The map
  # form of a broadcast is forwarded to subscribers as-is, so a control key there would leak.
  @spec persist_intent(payload) :: boolean()
  def persist_intent({_event, _encoding, _payload, metadata}) when is_map(metadata),
    do: metadata["persist"] == true

  def persist_intent(_payload), do: false

  defp run_authorization_check(policies, db_conn, authorization_context, persist_intent) do
    case extensions_to_probe(policies, persist_intent) do
      [] -> {:ok, policies}
      extensions -> Authorization.get_write_authorizations(policies, db_conn, authorization_context, extensions)
    end
  end
end
