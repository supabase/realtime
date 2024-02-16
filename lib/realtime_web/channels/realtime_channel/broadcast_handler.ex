defmodule RealtimeWeb.RealtimeChannel.BroadcastHandler do
  @moduledoc """
  Handles the Broadcast feature from Realtime
  """
  import Phoenix.Socket, only: [assign: 3]

  alias Realtime.GenCounter
  alias Realtime.RateCounter

  alias RealtimeWeb.Endpoint

  @event_type "broadcast"
  @spec call(map(), Phoenix.Socket.t()) ::
          {:reply, :ok, Phoenix.Socket.t()} | {:noreply, Phoenix.Socket.t()}
  def call(
        payload,
        %{
          assigns: %{
            is_new_api: true,
            ack_broadcast: ack_broadcast,
            self_broadcast: self_broadcast,
            tenant_topic: tenant_topic
          }
        } = socket
      ) do
    socket = count(socket)

    if self_broadcast,
      do: Endpoint.broadcast(tenant_topic, @event_type, payload),
      else: Endpoint.broadcast_from(self(), tenant_topic, @event_type, payload)

    if ack_broadcast,
      do: {:reply, :ok, socket},
      else: {:noreply, socket}
  end

  def call(_payload, socket) do
    {:noreply, socket}
  end

  defp count(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)

    assign(socket, :rate_counter, rate_counter)
  end
end
