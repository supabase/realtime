defmodule RealtimeWeb.RealtimeChannel.PresenceHandler do
  @moduledoc """
  Handles the Presence feature from Realtime
  """
  require Logger

  import Phoenix.Socket, only: [assign: 3]
  import Phoenix.Channel, only: [push: 3]
  import Realtime.Logs

  alias Phoenix.Socket
  alias Phoenix.Tracker.Shard
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias RealtimeWeb.Presence
  alias RealtimeWeb.RealtimeChannel.Logging

  @spec handle(map(), Phoenix.Socket.t()) :: {:reply, :error | :ok, Phoenix.Socket.t()}
  def handle(%{"event" => event} = payload, socket) do
    event = String.downcase(event, :ascii)

    case handle_presence_event(event, payload, socket) do
      {:ok, socket} -> {:reply, :ok, socket}
      {:error, socket} -> {:reply, :error, socket}
    end
  end

  def handle(_payload, socket), do: {:noreply, socket}

  @doc """
  Sends presence state to connected clients
  """
  @spec sync(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def sync(%{assigns: %{private?: false}} = socket) do
    %{assigns: %{tenant_topic: topic}} = socket
    socket = count(socket)
    push(socket, "presence_state", presence_dirty_list(topic))
    {:noreply, socket}
  end

  def sync(%{assigns: assigns} = socket) do
    %{tenant_topic: topic, policies: policies} = assigns

    socket =
      case policies do
        %Policies{presence: %PresencePolicies{read: false}} ->
          Logger.info("Presence track message ignored on #{topic}")
          socket

        _ ->
          socket = Logging.maybe_log_handle_info(socket, :sync_presence)
          push(socket, "presence_state", presence_dirty_list(topic))
          socket
      end

    {:noreply, socket}
  end

  defp handle_presence_event("track", payload, %{assigns: %{private?: false}} = socket) do
    track(socket, payload)
  end

  defp handle_presence_event(
         "track",
         payload,
         %{assigns: %{private?: true, policies: %Policies{presence: %PresencePolicies{write: nil}}}} = socket
       ) do
    %{assigns: %{db_conn: db_conn, authorization_context: authorization_context}} = socket

    case run_authorization_check(socket, db_conn, authorization_context) do
      {:ok, socket} ->
        handle_presence_event("track", payload, socket)

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:error, socket}
    end
  end

  defp handle_presence_event(
         "track",
         payload,
         %{assigns: %{private?: true, policies: %Policies{presence: %PresencePolicies{write: true}}}} = socket
       ) do
    track(socket, payload)
  end

  defp handle_presence_event(
         "track",
         _,
         %{assigns: %{private?: true, policies: %Policies{presence: %PresencePolicies{write: false}}}} = socket
       ) do
    {:error, socket}
  end

  defp handle_presence_event("untrack", _, socket) do
    %{assigns: %{presence_key: presence_key, tenant_topic: tenant_topic}} = socket
    {Presence.untrack(self(), tenant_topic, presence_key), socket}
  end

  defp handle_presence_event(event, _, socket) do
    log_error("UnknownPresenceEvent", event)
    {:error, socket}
  end

  defp track(socket, payload) do
    %{assigns: %{presence_key: presence_key, tenant_topic: tenant_topic}} = socket
    payload = Map.get(payload, "payload", %{})

    case Presence.track(self(), tenant_topic, presence_key, payload) do
      {:ok, _} ->
        {:ok, socket}

      {:error, {:already_tracked, pid, _, _}} ->
        case Presence.update(pid, tenant_topic, presence_key, payload) do
          {:ok, _} -> {:ok, socket}
          {:error, _} -> {:error, socket}
        end

      {:error, error} ->
        log_error("UnableToTrackPresence", error)
        {:error, socket}
    end
  end

  defp count(%{assigns: %{presence_rate_counter: presence_counter}} = socket) do
    GenCounter.add(presence_counter.id)
    {:ok, presence_rate_counter} = RateCounter.get(presence_counter.id)

    assign(socket, :presence_rate_counter, presence_rate_counter)
  end

  defp presence_dirty_list(topic) do
    [{:pool_size, size}] = :ets.lookup(Presence, :pool_size)

    Presence
    |> Shard.name_for_topic(topic, size)
    |> Shard.dirty_list(topic)
    |> Phoenix.Presence.group()
  end

  defp run_authorization_check(
         %Socket{assigns: %{private?: true, policies: %{presence: %PresencePolicies{write: nil}}}} = socket,
         db_conn,
         authorization_context
       ) do
    Authorization.get_write_authorizations(socket, db_conn, authorization_context)
  end

  defp run_authorization_check(socket, _db_conn, _authorization_context) do
    {:ok, socket}
  end
end
