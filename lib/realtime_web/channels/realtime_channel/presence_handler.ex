defmodule RealtimeWeb.RealtimeChannel.PresenceHandler do
  @moduledoc """
  Handles the Presence feature from Realtime
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]
  import Phoenix.Channel, only: [push: 3]

  alias Phoenix.Socket
  alias Phoenix.Tracker.Shard
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias RealtimeWeb.Presence
  alias RealtimeWeb.RealtimeChannel.Logging

  defguard is_private?(socket) when socket.assigns.private?

  defguard can_read_presence?(socket) when is_private?(socket) and socket.assigns.policies.presence.read

  defguard can_write_presence?(socket) when is_private?(socket) and socket.assigns.policies.presence.write

  @doc """
  Sends presence state to connected clients
  """
  @spec sync(Socket.t()) :: :ok | {:error, :rate_limit_exceeded}
  def sync(%{assigns: %{presence_enabled?: false}}), do: :ok

  def sync(socket) when not is_private?(socket) do
    %{assigns: %{tenant_topic: topic}} = socket

    with :ok <- limit_presence_event(socket) do
      push(socket, "presence_state", presence_dirty_list(topic))
      Logging.maybe_log_info(socket, :sync_presence)

      :ok
    end
  end

  def sync(socket) when not can_read_presence?(socket), do: :ok

  def sync(socket) when can_read_presence?(socket) do
    %{tenant_topic: topic} = socket.assigns

    with :ok <- limit_presence_event(socket) do
      push(socket, "presence_state", presence_dirty_list(topic))
      Logging.maybe_log_info(socket, :sync_presence)

      :ok
    end
  end

  @spec handle(map(), pid() | nil, Socket.t()) ::
          {:ok, Socket.t()}
          | {:error, :rls_policy_error | :unable_to_set_policies | :rate_limit_exceeded | :unable_to_track_presence}
  def handle(%{"event" => event} = payload, db_conn, socket) do
    event = String.downcase(event, :ascii)
    handle_presence_event(event, payload, db_conn, socket)
  end

  def handle(_, _, socket), do: {:ok, socket}

  defp handle_presence_event("track", payload, _, socket) when not is_private?(socket) do
    track(socket, payload)
  end

  defp handle_presence_event("track", payload, db_conn, socket)
       when is_private?(socket) and is_nil(socket.assigns.policies.presence.write) do
    %{assigns: %{authorization_context: authorization_context, policies: policies}} = socket

    case Authorization.get_write_authorizations(policies, db_conn, authorization_context) do
      {:ok, policies} ->
        socket = assign(socket, :policies, policies)
        handle_presence_event("track", payload, db_conn, socket)

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)
        {:error, :rls_policy_error}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:error, :unable_to_set_policies}
    end
  end

  defp handle_presence_event("track", payload, _, socket) when can_write_presence?(socket) do
    track(socket, payload)
  end

  defp handle_presence_event("track", _, _, socket) when not can_write_presence?(socket) do
    {:error, :unauthorized}
  end

  defp handle_presence_event("untrack", _, _, socket) do
    %{assigns: %{presence_key: presence_key, tenant_topic: tenant_topic}} = socket
    :ok = Presence.untrack(self(), tenant_topic, presence_key)
    {:ok, socket}
  end

  defp handle_presence_event(event, _, _, _) do
    log_error("UnknownPresenceEvent", event)
    {:error, :unknown_presence_event}
  end

  defp track(socket, payload) do
    socket = assign(socket, :presence_enabled?, true)

    %{assigns: %{presence_key: presence_key, tenant_topic: tenant_topic}} = socket
    payload = Map.get(payload, "payload", %{})

    with :ok <- limit_presence_event(socket),
         {:ok, _} <- Presence.track(self(), tenant_topic, presence_key, payload) do
      {:ok, socket}
    else
      {:error, {:already_tracked, pid, _, _}} ->
        case Presence.update(pid, tenant_topic, presence_key, payload) do
          {:ok, _} -> {:ok, socket}
          {:error, _} -> {:error, :unable_to_track_presence}
        end

      {:error, :rate_limit_exceeded} ->
        {:error, :rate_limit_exceeded}

      {:error, error} ->
        log_error("UnableToTrackPresence", error)
        {:error, :unable_to_track_presence}
    end
  end

  defp presence_dirty_list(topic) do
    [{:pool_size, size}] = :ets.lookup(Presence, :pool_size)

    Presence
    |> Shard.name_for_topic(topic, size)
    |> Shard.dirty_list(topic)
    |> Phoenix.Presence.group()
  end

  defp limit_presence_event(socket) do
    %{assigns: %{presence_rate_counter: presence_counter, tenant: tenant_id}} = socket
    {:ok, rate_counter} = RateCounter.get(presence_counter)

    tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)

    if rate_counter.avg > tenant.max_presence_events_per_second do
      {:error, :rate_limit_exceeded}
    else
      GenCounter.add(presence_counter.id)
      :ok
    end
  end
end
