defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  require Logger
  import Phoenix.Socket, only: [assign: 3]
  import Realtime.Logs

  alias Phoenix.Socket
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias RealtimeWeb.Endpoint

  @event_type "broadcast"
  @spec handle(map(), Phoenix.Socket.t()) ::
          {:reply, :ok, Phoenix.Socket.t()} | {:noreply, Phoenix.Socket.t()}
  def handle(payload, %{assigns: %{private?: true}} = socket) do
    %{
      assigns: %{
        self_broadcast: self_broadcast,
        tenant_topic: tenant_topic,
        authorization_context: authorization_context,
        db_conn: db_conn
      }
    } = socket

    case run_authorization_check(socket, db_conn, authorization_context) do
      {:ok,
       %{assigns: %{ack_broadcast: ack_broadcast, policies: %Policies{broadcast: %BroadcastPolicies{write: true}}}} =
           socket} ->
        socket = increment_rate_counter(socket)
        send_message(self_broadcast, tenant_topic, payload)
        if ack_broadcast, do: {:reply, :ok, socket}, else: {:noreply, socket}

      {:ok, socket} ->
        {:noreply, socket}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:noreply, socket}
    end
  end

  def handle(payload, %{assigns: %{private?: false}} = socket) do
    %{
      assigns: %{
        tenant_topic: tenant_topic,
        self_broadcast: self_broadcast,
        ack_broadcast: ack_broadcast
      }
    } = socket

    socket = increment_rate_counter(socket)
    send_message(self_broadcast, tenant_topic, payload)

    if ack_broadcast,
      do: {:reply, :ok, socket},
      else: {:noreply, socket}
  end

  defp send_message(self_broadcast, tenant_topic, payload) do
    if self_broadcast,
      do: Endpoint.broadcast(tenant_topic, @event_type, payload),
      else: Endpoint.broadcast_from(self(), tenant_topic, @event_type, payload)
  end

  defp increment_rate_counter(%{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{write: false}}}} = socket) do
    socket
  end

  defp increment_rate_counter(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)
    assign(socket, :rate_counter, rate_counter)
  end

  defp run_authorization_check(
         %Socket{assigns: %{policies: %{broadcast: %BroadcastPolicies{write: nil}}}} = socket,
         db_conn,
         authorization_context
       ) do
    Authorization.get_write_authorizations(socket, db_conn, authorization_context)
  end

  defp run_authorization_check(socket, _db_conn, _authorization_context) do
    {:ok, socket}
  end
end
