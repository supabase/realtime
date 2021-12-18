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
        params,
        %Socket{channel_pid: channel_pid, assigns: %{access_token: access_token}} = socket
      ) do
    with token when is_binary(token) <- params["user_token"] || access_token,
         {:ok, %{"role" => role} = claims} <- ChannelsAuthorization.authorize(token),
         bin_id <- Ecto.UUID.bingenerate(),
         :ok <-
           SubscriptionManager.track_topic_subscriber(%{
             id: bin_id,
             channel_pid: channel_pid,
             claims: claims,
             topic: subtopic
           }),
         :ok <- PubSub.subscribe(Realtime.PubSub, "subscription_manager") do
      SocketMonitor.track_channel(socket)
      send(self(), :after_join)
      ref = Process.send_after(self(), :verify_access_token, @verify_token_interval)

      {:ok, assign(socket, %{id: bin_id, access_token: token, role: role, verify_ref: ref})}
    else
      _ -> {:error, %{reason: "error occurred when joining #{topic} with user token"}}
    end
  end

  def join(_, _, socket) do
    SocketMonitor.track_channel(socket)
    {:ok, socket}
  end

  def handle_info(
        :after_join,
        %Socket{
          assigns: %{id: id, access_token: access_token},
          pubsub_server: pubsub_server,
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    case ChannelsAuthorization.authorize(access_token) do
      {:ok, _} ->
        :ok = PubSub.unsubscribe(pubsub_server, topic)
        subscriber_fastlane = {:subscriber_fastlane, transport_pid, serializer, id}
        :ok = PubSub.subscribe(pubsub_server, topic, metadata: subscriber_fastlane)
        {:noreply, socket}

      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        %Socket{
          assigns: %{id: id, access_token: access_token},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    with {:ok, claims} <- ChannelsAuthorization.authorize(access_token),
         :ok <-
           SubscriptionManager.track_topic_subscriber(%{
             id: id,
             channel_pid: channel_pid,
             claims: claims,
             topic: subtopic
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

      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in(
        "access_token",
        %{"access_token" => fresh_token},
        %Socket{
          assigns: %{id: id, access_token: _, role: role},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    if role == "authenticated" do
      with {:ok, %{"role" => new_role} = claims} <- ChannelsAuthorization.authorize(fresh_token),
           :ok <-
             SubscriptionManager.track_topic_subscriber(%{
               id: id,
               channel_pid: channel_pid,
               claims: claims,
               topic: subtopic
             }) do
        {:noreply, assign(socket, %{access_token: fresh_token, role: new_role})}
      else
        _ -> {:stop, :invalid_access_token, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end
end
