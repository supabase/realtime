defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias Extensions.AiAgent.Session
  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.AiPolicies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.TenantBroadcaster

  @type payload :: map | {String.t(), :json | :binary, binary, map()}

  @ai_events ["agent_input", "agent_cancel"]
  @event_type "broadcast"

  @spec handle(payload, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(%{"event" => event}, %{assigns: %{private?: false}} = socket) when event in @ai_events do
    {:noreply, socket}
  end

  def handle(payload, %{assigns: %{private?: false}} = socket), do: handle(payload, nil, socket)

  @spec handle(payload, pid() | nil, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(%{"event" => event} = payload, db_conn, %{assigns: %{ai_session: pid, private?: true}} = socket)
      when event in @ai_events and is_pid(pid) do
    handle_ai_event(event, payload, db_conn, socket)
  end

  def handle(
        {event, :json, payload_binary, _metadata},
        db_conn,
        %{assigns: %{ai_session: pid, private?: true}} = socket
      )
      when event in @ai_events and is_pid(pid) do
    payload = %{"event" => event, "payload" => Phoenix.json_library().decode!(payload_binary)}
    handle_ai_event(event, payload, db_conn, socket)
  end

  def handle({_, _, _, _} = payload, db_conn, %{assigns: %{private?: true}} = socket) do
    broadcast = build_user_broadcast(socket.assigns.tenant_topic, payload)
    broadcast_authorized(broadcast, :ok, db_conn, socket)
  end

  def handle(payload, db_conn, %{assigns: %{private?: true}} = socket) do
    %{assigns: %{tenant_topic: topic}} = socket
    broadcast = %Phoenix.Socket.Broadcast{topic: topic, event: @event_type, payload: payload}
    broadcast_authorized(broadcast, payload, db_conn, socket)
  end

  def handle({_, _, _, _} = payload, _db_conn, %{assigns: %{private?: false}} = socket) do
    broadcast = build_user_broadcast(socket.assigns.tenant_topic, payload)
    broadcast_public(broadcast, :ok, socket)
  end

  def handle(payload, _db_conn, %{assigns: %{private?: false}} = socket) do
    %{assigns: %{tenant_topic: topic}} = socket
    broadcast = %Phoenix.Socket.Broadcast{topic: topic, event: @event_type, payload: payload}
    broadcast_public(broadcast, payload, socket)
  end

  defp build_user_broadcast(topic, {user_event, user_payload_encoding, user_payload, _metadata}) do
    %RealtimeWeb.Socket.UserBroadcast{
      topic: topic,
      user_event: user_event,
      user_payload_encoding: user_payload_encoding,
      user_payload: user_payload
    }
  end

  defp broadcast_authorized(broadcast, payload_or_size_check, db_conn, socket) do
    %{assigns: %{authorization_context: authorization_context, policies: policies}} = socket

    case check_broadcast_authorization(policies || %Policies{}, db_conn, authorization_context) do
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} ->
        socket = socket |> assign(:policies, policies) |> increment_rate_counter()
        res = do_send(broadcast, payload_or_size_check, socket)
        reply_for_result(res, socket.assigns.ack_broadcast, socket)

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

  defp broadcast_public(broadcast, payload_or_size_check, socket) do
    socket = increment_rate_counter(socket)
    res = do_send(broadcast, payload_or_size_check, socket)
    reply_for_result(res, socket.assigns.ack_broadcast, socket)
  end

  defp do_send(
         broadcast,
         payload_or_size_check,
         %{assigns: %{tenant: tenant_id, self_broadcast: self_broadcast, tenant_topic: tenant_topic}} = _socket
       ) do
    size_check =
      case payload_or_size_check do
        :ok -> :ok
        payload -> Tenants.validate_payload_size(tenant_id, payload)
      end

    case size_check do
      :ok -> pubsub_send(tenant_id, self_broadcast, tenant_topic, broadcast)
      error -> error
    end
  end

  defp reply_for_result(res, ack_broadcast, socket) do
    cond do
      ack_broadcast && match?({:error, :payload_size_exceeded}, res) ->
        {:reply, {:error, :payload_size_exceeded}, socket}

      ack_broadcast ->
        {:reply, :ok, socket}

      true ->
        {:noreply, socket}
    end
  end

  defp pubsub_send(tenant_id, true, tenant_topic, broadcast) do
    TenantBroadcaster.pubsub_broadcast(
      tenant_id,
      tenant_topic,
      broadcast,
      RealtimeChannel.MessageDispatcher,
      :broadcast
    )
  end

  defp pubsub_send(tenant_id, false, tenant_topic, broadcast) do
    TenantBroadcaster.pubsub_broadcast_from(
      tenant_id,
      self(),
      tenant_topic,
      broadcast,
      RealtimeChannel.MessageDispatcher,
      :broadcast
    )
  end

  defp increment_rate_counter(%{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{write: false}}}} = socket) do
    socket
  end

  defp increment_rate_counter(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    socket
  end

  defp check_broadcast_authorization(%Policies{broadcast: %BroadcastPolicies{write: nil}} = policies, db_conn, ctx) do
    Authorization.get_write_authorizations(policies, db_conn, ctx)
  end

  defp check_broadcast_authorization(policies, _db_conn, _ctx), do: {:ok, policies}

  defp check_ai_authorization(%Policies{ai_agent: %AiPolicies{write: nil}} = policies, db_conn, ctx) do
    Authorization.get_write_authorizations(policies, db_conn, ctx, ai_enabled?: true)
  end

  defp check_ai_authorization(policies, _db_conn, _ctx), do: {:ok, policies}

  defp handle_ai_event(event, payload, db_conn, socket) do
    %{
      authorization_context: authorization_context,
      policies: policies,
      ai_session: pid
    } = socket.assigns

    case check_ai_authorization(policies || %Policies{}, db_conn, authorization_context) do
      {:ok, %Policies{ai_agent: %AiPolicies{write: true}} = policies} ->
        socket = assign(socket, :policies, policies)
        route_ai_event(event, payload["payload"] || %{}, pid)
        {:noreply, socket}

      {:ok, _policies} ->
        {:noreply, socket}

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)
        {:noreply, socket}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:noreply, socket}
    end
  end

  defp route_ai_event("agent_input", payload, pid), do: Session.handle_input(pid, payload)
  defp route_ai_event("agent_cancel", _payload, pid), do: Session.cancel(pid)
end
