defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  alias Phoenix.{PubSub, Socket}
  alias Phoenix.Socket.Broadcast
  alias Realtime.SubscriptionManager
  alias RealtimeWeb.ChannelsAuthorization

  def join("realtime:", _, _socket) do
    {:error, %{reason: "realtime subtopic does not exist"}}
  end

  def join("realtime:" <> subtopic = topic, %{"user_token" => token}, socket) do
    with {:ok, %{"sub" => user_id}} <- ChannelsAuthorization.authorize(token),
         :ok <- PubSub.subscribe(Realtime.PubSub, "subscription_manager"),
         {:ok, bin_user_id} <- Ecto.UUID.dump(user_id),
         %Socket{assigns: %{user_id: _}, channel_pid: channel_pid} = user_socket <-
           assign(socket, :user_id, bin_user_id),
         :ok <-
           SubscriptionManager.track_topic_subscriber(%{
             channel_pid: channel_pid,
             topic: subtopic,
             user_id: bin_user_id
           }) do
      send(self(), :after_join)
      {:ok, user_socket}
    else
      _ -> {:error, %{reason: "error occurred when joining #{topic}"}}
    end
  end

  def join("realtime:" <> _, _, socket) do
    {:ok, socket}
  end

  def handle_info(
        :after_join,
        %Socket{
          assigns: %{user_id: user_id},
          pubsub_server: pubsub_server,
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    :ok = PubSub.unsubscribe(pubsub_server, topic)
    user_fastlane = {:user_fastlane, transport_pid, serializer, user_id}
    :ok = PubSub.subscribe(pubsub_server, topic, metadata: user_fastlane)

    {:noreply, socket}
  end

  def handle_info(:after_join, socket), do: {:noreply, socket}

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        %Socket{
          assigns: %{user_id: user_id},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    case SubscriptionManager.track_topic_subscriber(%{
           channel_pid: channel_pid,
           topic: subtopic,
           user_id: user_id
         }) do
      :ok -> {:noreply, socket}
      :error -> {:stop, :track_topic_subscriber_error, socket}
    end
  end

  def handle_info(:after_join, socket) do
    Realtime.Metrics.SocketMonitor.track_channel(socket)
    {:noreply, socket}
  end

  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end
end
