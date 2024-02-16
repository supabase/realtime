defmodule RealtimeWeb.RealtimeChannel.PresenceHandler do
  @moduledoc """
  Handles the Presence feature from Realtime
  """
  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.GenCounter
  alias Realtime.RateCounter

  alias RealtimeWeb.Presence

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

  defp handle_presence_event(event, payload, socket) do
    %{assigns: %{presence_key: presence_key, tenant_topic: tenant_topic}} = socket

    case String.downcase(event) do
      "track" ->
        with payload <- Map.get(payload, "payload", %{}),
             {:error, {:already_tracked, _, _, _}} <-
               Presence.track(self(), tenant_topic, presence_key, payload),
             {:ok, _} <- Presence.update(self(), tenant_topic, presence_key, payload) do
          :ok
        else
          {:ok, _} -> :ok
          {:error, _} -> :error
        end

      "untrack" ->
        Presence.untrack(self(), tenant_topic, presence_key)

      _ ->
        :error
    end
  end

  defp count(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)

    assign(socket, :rate_counter, rate_counter)
  end
end
