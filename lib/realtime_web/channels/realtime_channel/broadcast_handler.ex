defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]

  alias RealtimeWeb.TenantBroadcaster
  alias Phoenix.Socket
  alias Realtime.Api.Tenant
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Cache

  @event_type "broadcast"
  @spec handle(map(), Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(payload, %{assigns: %{private?: false}} = socket), do: handle(payload, nil, socket)

  @spec handle(map(), pid() | nil, Socket.t()) :: {:reply, :ok, Socket.t()} | {:noreply, Socket.t()}
  def handle(payload, db_conn, %{assigns: %{private?: true}} = socket) do
    %{
      assigns: %{
        self_broadcast: self_broadcast,
        tenant_topic: tenant_topic,
        authorization_context: authorization_context,
        policies: policies
      }
    } = socket

    case run_authorization_check(policies || %Policies{}, db_conn, authorization_context) do
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}} = policies} ->
        socket =
          socket
          |> assign(:policies, policies)
          |> increment_rate_counter()

        %{ack_broadcast: ack_broadcast, tenant: tenant_id} = socket.assigns
        send_message(tenant_id, self_broadcast, tenant_topic, payload)
        if ack_broadcast, do: {:reply, :ok, socket}, else: {:noreply, socket}

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
    send_message(tenant_id, self_broadcast, tenant_topic, payload)

    if ack_broadcast,
      do: {:reply, :ok, socket},
      else: {:noreply, socket}
  end

  defp send_message(tenant_id, self_broadcast, tenant_topic, payload) do
    with %Tenant{} = tenant <- Cache.get_tenant_by_external_id(tenant_id) do
      if self_broadcast do
        TenantBroadcaster.broadcast(tenant, tenant_topic, @event_type, payload)
      else
        TenantBroadcaster.broadcast_from(tenant, self(), tenant_topic, @event_type, payload)
      end
    end
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
