defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.Messages
  alias Realtime.Tenants
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.TenantBroadcaster
  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PersistencePolicies

  @type payload :: map | {String.t(), :json | :binary, binary, map()}

  @event_type "broadcast"

  @doc """
  Handles an outgoing broadcast for a channel.

  `db_conn` is `nil` for public channels which don't write authorization nor persist messages.  is the tenant database connection, used to run write authorization and to persist the
  """
  @spec handle(payload, db_conn :: pid() | nil, Socket.t()) ::
          {:reply, :ok, Socket.t()}
          | {:reply, {:ok, map()}, Socket.t()}
          | {:reply, {:error, any()}, Socket.t()}
          | {:noreply, Socket.t()}
  def handle(payload, db_conn, %{assigns: %{private?: true}} = socket) do
    %{
      assigns: %{
        self_broadcast: self_broadcast,
        tenant_topic: tenant_topic,
        authorization_context: authorization_context,
        policies: policies,
        tenant: tenant_id,
        ack_broadcast: ack_broadcast
      }
    } = socket

    with {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} <-
           run_authorization_check(policies || %Policies{}, db_conn, authorization_context),
         socket = socket |> assign(:policies, policies) |> increment_rate_counter(),
         :ok <- Tenants.validate_payload_size(tenant_id, payload) do
      # Persist before broadcasting to permit recovering/replaying messages in case of failure.
      persist_result = maybe_persist(policies, db_conn, authorization_context.topic, payload)

      send_message(tenant_id, self_broadcast, tenant_topic, payload)

      cond do
        match?({:error, _reason}, persist_result) ->
          {:error, reason} = persist_result
          log_error("UnableToPersistBroadcast", reason)
          if ack_broadcast, do: {:reply, :ok, socket}, else: {:noreply, socket}

        ack_broadcast and match?({:ok, _id}, persist_result) ->
          {:ok, id} = persist_result
          {:reply, {:ok, %{id: id}}, socket}

        ack_broadcast ->
          {:reply, :ok, socket}

        true ->
          {:noreply, socket}
      end
    else
      {:ok, policies} ->
        {:noreply, assign(socket, :policies, policies)}

      {:error, :payload_size_exceeded} ->
        if ack_broadcast, do: {:reply, {:error, :payload_size_exceeded}, socket}, else: {:noreply, socket}

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

    case Tenants.validate_payload_size(tenant_id, payload) do
      :ok ->
        send_message(tenant_id, self_broadcast, tenant_topic, payload)
        if ack_broadcast, do: {:reply, :ok, socket}, else: {:noreply, socket}

      {:error, :payload_size_exceeded} ->
        if ack_broadcast,
          do: {:reply, {:error, :payload_size_exceeded}, socket},
          else: {:noreply, socket}
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

  defp maybe_persist(%Policies{persistence: %PersistencePolicies{write: true}}, db_conn, topic, payload) do
    case convert_to_persistable_fields(payload) do
      {:ok, event, event_payload} -> Messages.persist(db_conn, topic, event, event_payload)
      :error -> :skip
    end
  end

  defp maybe_persist(_policies, _db_conn, _topic, _payload), do: :skip

  defp convert_to_persistable_fields(%{"event" => event, "payload" => payload}), do: {:ok, event, payload}

  defp convert_to_persistable_fields({event, :json, user_payload, _metadata}) do
    case Jason.decode(user_payload) do
      {:ok, payload} -> {:ok, event, payload}
      {:error, _} -> :error
    end
  end

  defp convert_to_persistable_fields(_payload), do: :error

  defp increment_rate_counter(%{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{write: false}}}} = socket) do
    socket
  end

  defp increment_rate_counter(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    socket
  end

  defp run_authorization_check(
         %Policies{broadcast: %BroadcastPolicies{write: nil}} = policies,
         db_conn,
         authorization_context
       ) do
    Authorization.get_write_authorizations(policies, db_conn, authorization_context)
  end

  defp run_authorization_check(socket, _db_conn, _authorization_context) do
    {:ok, socket}
  end
end
