defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  alias Phoenix.{PubSub, Socket}
  alias Phoenix.Socket.Broadcast
  alias Realtime.SubscriptionManager
  alias Realtime.Metrics.SocketMonitor
  alias RealtimeWeb.ChannelsAuthorization

  @verify_token_interval 60_000

  def join("realtime:", _, _socket) do
    {:error, %{reason: "realtime subtopic does not exist"}}
  end

  def join(
        "realtime:" <> subtopic = topic,
        %{"user_token" => access_token},
        %Socket{channel_pid: channel_pid} = socket
      ) do
    case ChannelsAuthorization.authorize(access_token) do
      {:ok, %{"sub" => user_id, "email" => email}} ->
        with :ok <- PubSub.subscribe(Realtime.PubSub, "subscription_manager"),
             {:ok, bin_user_id} <- Ecto.UUID.dump(user_id),
             :ok <-
               SubscriptionManager.track_topic_subscriber(%{
                 channel_pid: channel_pid,
                 topic: subtopic,
                 user_id: bin_user_id,
                 email: email
               }) do
          SocketMonitor.track_channel(socket)
          send(self(), :after_join)
          ref = Process.send_after(self(), :verify_access_token, @verify_token_interval)

          {:ok, assign(socket, %{access_token: access_token, verify_ref: ref})}
        else
          _ -> {:error, %{reason: "error occurred when joining #{topic} with user token"}}
        end

      {:ok, _} ->
        SocketMonitor.track_channel(socket)
        {:ok, socket}

      _ ->
        {:error, %{reason: "user token is invalid"}}
    end
  end

  def join("realtime:" <> _, _, socket) do
    SocketMonitor.track_channel(socket)
    {:ok, socket}
  end

  def handle_info(
        :after_join,
        %Socket{
          assigns: %{access_token: access_token},
          pubsub_server: pubsub_server,
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    with {:ok, %{"sub" => user_id}} <- ChannelsAuthorization.authorize(access_token),
         {:ok, bin_user_id} <- Ecto.UUID.dump(user_id) do
      :ok = PubSub.unsubscribe(pubsub_server, topic)
      user_fastlane = {:user_fastlane, transport_pid, serializer, bin_user_id}
      :ok = PubSub.subscribe(pubsub_server, topic, metadata: user_fastlane)
      {:noreply, socket}
    else
      _ -> {:stop, :invalid_access_token, socket}
    end
  end

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        %Socket{
          assigns: %{access_token: access_token},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    with {:ok, %{"sub" => user_id, "email" => email}} <-
           ChannelsAuthorization.authorize(access_token),
         {:ok, bin_user_id} <- Ecto.UUID.dump(user_id),
         :ok <-
           SubscriptionManager.track_topic_subscriber(%{
             channel_pid: channel_pid,
             topic: subtopic,
             user_id: bin_user_id,
             email: email
           }) do
      {:noreply, socket}
    else
      _ -> {:stop, :sync_subscription_error, socket}
    end
  end

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        socket
      ) do
    {:noreply, socket}
  end

  def handle_info(
        :verify_access_token,
        %Socket{
          assigns: %{access_token: access_token, verify_ref: ref}
        } = socket
      ) do
    Process.cancel_timer(ref)

    case ChannelsAuthorization.authorize(access_token) do
      {:ok, _} ->
        ref = Process.send_after(self(), :verify_access_token, @verify_token_interval)
        {:noreply, assign(socket, :verify_ref, ref)}

      :error ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in(
        "access_token",
        %{"access_token" => fresh_token},
        %Socket{
          assigns: %{access_token: _},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    with {:ok, %{"sub" => user_id, "email" => email}} <-
           ChannelsAuthorization.authorize(fresh_token),
         {:ok, bin_user_id} <- Ecto.UUID.dump(user_id),
         :ok <-
           SubscriptionManager.track_topic_subscriber(%{
             channel_pid: channel_pid,
             topic: subtopic,
             user_id: bin_user_id,
             email: email
           }) do
      {:noreply, assign(socket, :access_token, fresh_token)}
    else
      _ -> {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end
end
