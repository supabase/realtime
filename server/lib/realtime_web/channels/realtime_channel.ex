defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  alias Phoenix.{PubSub, Socket}
  alias Phoenix.Socket.Broadcast
  alias Realtime.SubscriptionManager
  alias Realtime.Metrics.SocketMonitor
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint}

  @verify_token_interval 60_000

  def join("realtime:", _, _socket) do
    {:error, %{reason: "realtime subtopic does not exist"}}
  end

  def join(
        "realtime:" <> subtopic = topic,
        params,
        %Socket{channel_pid: channel_pid, assigns: %{access_token: access_token}} = socket
      ) do
    token =
      case params do
        %{"user_token" => token} -> token
        _ -> access_token
      end

    with {:ok, claims} <- ChannelsAuthorization.authorize(token),
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

      {:ok, assign(socket, %{id: bin_id, access_token: token, verify_ref: ref})}
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
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    with {:ok, _} <- ChannelsAuthorization.authorize(access_token),
         :ok <- Endpoint.unsubscribe(topic),
         :ok <-
           Endpoint.subscribe(topic,
             metadata: {:subscriber_fastlane, transport_pid, serializer, id}
           ) do
      {:noreply, socket}
    else
      error -> {:stop, error, socket}
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
          assigns: %{id: id, access_token: access_token},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      )
      when is_binary(fresh_token) do
    case ChannelsAuthorization.authorize(fresh_token) do
      {:ok, fresh_claims} ->
        new_socket =
          if fresh_token != access_token do
            SubscriptionManager.track_topic_subscriber(%{
              id: id,
              channel_pid: channel_pid,
              claims: fresh_claims,
              topic: subtopic
            })

            assign(socket, :access_token, fresh_token)
          else
            socket
          end

        {:noreply, new_socket}

      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end
end
