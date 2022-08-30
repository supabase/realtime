defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  alias Phoenix.{PubSub, Socket}
  alias Phoenix.Socket.Broadcast
  alias Realtime.SubscriptionManager
  alias Realtime.Metrics.SocketMonitor
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint}

  @verify_token_ms 1_000 * 60 * 5

  def join(
        "realtime:" <> subtopic = topic,
        params,
        %Socket{
          assigns: %{access_token: access_token},
          channel_pid: channel_pid
        } = socket
      ) do
    with token when is_binary(token) <-
           (case params do
              %{"user_token" => token} -> token
              _ -> access_token
            end),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize(token),
         bin_id <- Ecto.UUID.bingenerate(),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         verify_token_ref <-
           Process.send_after(
             self(),
             :verify_token,
             min(@verify_token_ms, exp_diff * 1_000)
           ),
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

      {:ok,
       assign(socket, %{id: bin_id, access_token: token, verify_token_ref: verify_token_ref})}
    else
      _ -> {:error, %{reason: "error occurred when joining #{topic}"}}
    end
  end

  def join(_, _, socket) do
    SocketMonitor.track_channel(socket)
    {:ok, socket}
  end

  def handle_info(
        :after_join,
        %Socket{
          assigns: %{id: id},
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    with :ok <- Endpoint.unsubscribe(topic),
         :ok <-
           Endpoint.subscribe(topic,
             metadata: {:subscriber_fastlane, transport_pid, serializer, id}
           ) do
      {:noreply, socket}
    else
      _ -> {:stop, :subscriber_fastlane_subscribe_error, socket}
    end
  end

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        %Socket{
          assigns: %{id: id, access_token: token},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      ) do
    with {:ok, claims} <- ChannelsAuthorization.authorize(token),
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
        :verify_token,
        %Socket{
          assigns: %{access_token: access_token, verify_token_ref: ref}
        } = socket
      ) do
    Process.cancel_timer(ref)

    with {:ok, %{"exp" => exp}} <- ChannelsAuthorization.authorize(access_token),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         verify_token_ref <-
           Process.send_after(
             self(),
             :verify_token,
             min(@verify_token_ms, exp_diff * 1_000)
           ) do
      {:noreply, assign(socket, :verify_token_ref, verify_token_ref)}
    else
      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in(
        "access_token",
        %{"access_token" => fresh_token},
        %Socket{
          assigns: %{id: id, access_token: access_token, verify_token_ref: ref},
          channel_pid: channel_pid,
          topic: "realtime:" <> subtopic
        } = socket
      )
      when is_binary(fresh_token) do
    Process.cancel_timer(ref)

    with {:ok, %{"exp" => exp} = fresh_claims} <- ChannelsAuthorization.authorize(fresh_token),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         verify_token_ref <-
           Process.send_after(
             self(),
             :verify_token,
             min(@verify_token_ms, exp_diff * 1_000)
           ) do
      new_socket =
        if fresh_token != access_token do
          SubscriptionManager.track_topic_subscriber(%{
            id: id,
            channel_pid: channel_pid,
            claims: fresh_claims,
            topic: subtopic
          })

          assign(socket, %{access_token: fresh_token, verify_token_ref: verify_token_ref})
        else
          assign(socket, :verify_token_ref, verify_token_ref)
        end

      {:noreply, new_socket}
    else
      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end
end
