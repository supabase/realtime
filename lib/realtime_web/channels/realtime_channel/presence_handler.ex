defmodule RealtimeWeb.RealtimeChannel.PresenceHandler do
  @moduledoc """
  Handles the Presence feature from Realtime
  """
  import Phoenix.Socket, only: [assign: 3]
  import Phoenix.Channel, only: [push: 3]
  require Logger
  alias Phoenix.Tracker.Shard

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies

  alias RealtimeWeb.Presence
  alias RealtimeWeb.RealtimeChannel.Logging

  @spec call(map(), Phoenix.Socket.t()) ::
          {:noreply, Phoenix.Socket.t()} | {:reply, :error | :ok, Phoenix.Socket.t()}
  def call(
        %{"event" => event} = payload,
        %{assigns: %{is_new_api: true, presence_key: _, tenant_topic: _}} = socket
      ) do
    socket = count(socket)
    result = handle_presence_event(event, payload, socket)

    {:reply, result, socket}
  end

  def call(_payload, socket) do
    {:noreply, socket}
  end

  def track(msg, %{assigns: assigns} = socket) do
    %{tenant_topic: topic, policies: policies} = assigns

    case policies do
      %Policies{presence: %PresencePolicies{write: false}} ->
        Logger.info("Presence track message ignored on #{topic}")
        {:noreply, socket}

      _ ->
        socket = Logging.maybe_log_handle_info(socket, msg)
        push(socket, "presence_state", presence_dirty_list(topic))

        {:noreply, socket}
    end
  end

  defp handle_presence_event(event, payload, socket) do
    %{
      assigns: %{
        presence_key: presence_key,
        tenant_topic: tenant_topic,
        policies: policies
      }
    } = socket

    cond do
      match?(%Policies{presence: %PresencePolicies{write: false}}, policies) ->
        Logger.info("Presence message ignored on #{tenant_topic}")
        :ok

      String.downcase(event) == "track" ->
        payload = Map.get(payload, "payload", %{})

        case Presence.track(self(), tenant_topic, presence_key, payload) do
          {:ok, _} ->
            :ok

          {:error, {:already_tracked, _, _, _}} ->
            case Presence.update(self(), tenant_topic, presence_key, payload) do
              {:ok, _} -> :ok
              {:error, _} -> :error
            end

          {:error, _} ->
            :error
        end

      String.downcase(event) == "untrack" ->
        Presence.untrack(self(), tenant_topic, presence_key)

      true ->
        :error
    end
  end

  defp count(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)

    assign(socket, :rate_counter, rate_counter)
  end

  defp presence_dirty_list(topic) do
    [{:pool_size, size}] = :ets.lookup(Presence, :pool_size)

    Presence
    |> Shard.name_for_topic(topic, size)
    |> Shard.dirty_list(topic)
    |> Phoenix.Presence.group()
  end
end
