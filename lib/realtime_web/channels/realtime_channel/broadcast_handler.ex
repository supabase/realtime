defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.Tenants
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.TenantBroadcaster
  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies

  @type payload :: map | {String.t(), :json | :binary, binary}

  @event_type "broadcast"
  @spec handle(payload, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(payload, %{assigns: %{private?: false}} = socket), do: handle(payload, nil, socket)

  @spec handle(payload, pid() | nil, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
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

    case run_authorization_check(policies || %Policies{}, db_conn, authorization_context) do
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} ->
        socket =
          socket
          |> assign(:policies, policies)
          |> increment_rate_counter()

        %{ack_broadcast: ack_broadcast} = socket.assigns

        res =
          case Tenants.validate_payload_size(tenant_id, payload) do
            :ok -> send_message(tenant_id, self_broadcast, tenant_topic, payload)
            {:error, error} -> {:error, error}
          end

        cond do
          ack_broadcast && match?({:error, :payload_size_exceeded}, res) ->
            {:reply, {:error, :payload_size_exceeded}, socket}

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
        {:error, error} -> {:error, error}
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
