defmodule RealtimeWeb.RealtimeChannel do
  use RealtimeWeb, :channel
  require Logger, warn: false

  alias Phoenix.{PubSub, Socket}
  alias Phoenix.Socket.Broadcast
  alias Realtime.SubscriptionManager
  alias Realtime.Metrics.SocketMonitor
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint, Presence}

  @verify_token_ms 1_000 * 60 * 5

  def join(
        "realtime:" <> subtopic = topic,
        params,
        %Socket{
          assigns: %{access_token: access_token},
          channel_pid: channel_pid,
          serializer: serializer,
          topic: topic,
          transport_pid: transport_pid
        } = socket
      ) do
    with token when is_binary(token) <-
           (case params do
              %{"user_token" => token} -> token
              _ -> access_token
            end),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize(token),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time() do
      verify_token_ref =
        Process.send_after(
          self(),
          :verify_token,
          min(@verify_token_ms, exp_diff * 1_000)
        )

      is_new_api =
        case params do
          %{"configs" => _} -> true
          _ -> false
        end

      if is_new_api do
        params["configs"]["postgres_changes"]
        |> case do
          [_ | _] = params_list ->
            pg_change_params =
              params_list
              |> Enum.map(fn params ->
                %{
                  id: Ecto.UUID.generate(),
                  channel_pid: channel_pid,
                  claims: claims,
                  params: params
                }
              end)

            pg_change_params
            |> SubscriptionManager.track_topic_subscribers()
            |> case do
              :ok -> {:ok, pg_change_params}
              :error -> :error
            end

          _ ->
            {:ok, []}
        end
      else
        params =
          case String.split(subtopic, ":", parts: 3) do
            [schema] ->
              %{"schema" => schema}

            [schema, table] ->
              %{"schema" => schema, "table" => table}

            [schema, table, filter] ->
              %{"schema" => schema, "table" => table, "filter" => filter}
          end

        pg_change_params = [
          %{
            id: Ecto.UUID.generate(),
            channel_pid: channel_pid,
            claims: claims,
            params: params
          }
        ]

        pg_change_params
        |> SubscriptionManager.track_topic_subscribers()
        |> case do
          :ok -> {:ok, pg_change_params}
          :error -> :error
        end
      end
      |> case do
        {:ok, pg_change_params} ->
          PubSub.subscribe(Realtime.PubSub, "subscription_manager")

          SocketMonitor.track_channel(socket)

          presence_key =
            with key when is_binary(key) <- params["configs"]["presence"]["key"],
                 true <- String.length(key) > 0 do
              key
            else
              _ -> Ecto.UUID.generate()
            end

          for %{id: id, params: params} <- pg_change_params do
            metadata =
              {:subscriber_fastlane, transport_pid, serializer, id, topic,
               params |> Map.get("event", "") |> String.upcase(), is_new_api}

            Endpoint.subscribe("postgres_changes:#{id}", metadata: metadata)
          end

          send(self(), :after_join)

          {
            :ok,
            %{
              postgres_changes:
                Enum.map(pg_change_params, fn %{id: id, params: params} ->
                  Map.put(params, :id, id)
                end)
            },
            assign(
              socket,
              %{
                access_token: token,
                ack_broadcast: !!params["configs"]["broadcast"]["ack"],
                is_new_api: is_new_api,
                pg_change_params: pg_change_params,
                presence_key: presence_key,
                self_broadcast: !!params["configs"]["broadcast"]["self"],
                verify_token_ref: verify_token_ref
              }
            )
          }

        :error ->
          {:error, %{reason: "unable to insert topic subscriptions into database"}}
      end
    else
      _ -> {:error, %{reason: "attempted to join channel #{topic} with invalid token"}}
    end
  end

  def join(_, _, socket) do
    SocketMonitor.track_channel(socket)
    {:ok, socket}
  end

  def handle_info(
        :after_join,
        %Socket{
          assigns: %{is_new_api: is_new_api},
          topic: topic
        } = socket
      ) do
    if is_new_api do
      push(socket, "presence_state", Presence.list(topic))
    end

    {:noreply, socket}
  end

  def handle_info(
        %Broadcast{
          event: "sync_subscription",
          topic: "subscription_manager"
        },
        %Socket{
          assigns: %{pg_change_params: [_ | _] = pg_change_params}
        } = socket
      ) do
    :ok = SubscriptionManager.track_topic_subscribers(pg_change_params)

    {:noreply, socket}
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
          assigns: %{
            access_token: access_token,
            pg_change_params: pg_change_params,
            verify_token_ref: ref
          }
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
          new_params =
            pg_change_params
            |> Enum.map(&Map.put(&1, :claims, fresh_claims))

          :ok = SubscriptionManager.track_topic_subscribers(new_params)

          assign(socket, %{
            access_token: fresh_token,
            pg_change_params: new_params,
            verify_token_ref: verify_token_ref
          })
        else
          assign(socket, :verify_token_ref, verify_token_ref)
        end

      {:noreply, new_socket}
    else
      _ ->
        {:stop, :invalid_access_token, socket}
    end
  end

  def handle_in(
        "broadcast" = type,
        payload,
        %Socket{
          assigns: %{
            is_new_api: true,
            ack_broadcast: ack_broadcast,
            self_broadcast: self_broadcast
          },
          topic: topic
        } = socket
      ) do
    if self_broadcast do
      Endpoint.broadcast(topic, type, payload)
    else
      Endpoint.broadcast_from(self(), topic, type, payload)
    end

    if ack_broadcast do
      {:reply, :ok, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_in(
        "presence",
        %{"event" => event, "payload" => payload},
        %Socket{assigns: %{is_new_api: true, presence_key: presence_key}, topic: topic} = socket
      ) do
    result =
      event
      |> String.downcase()
      |> case do
        "track" ->
          with {:error, {:already_tracked, _, _, _}} <-
                 Presence.track(self(), topic, presence_key, payload),
               {:ok, _} <- Presence.update(self(), topic, presence_key, payload) do
            :ok
          else
            {:ok, _} -> :ok
            {:error, _} -> :error
          end

        "untrack" ->
          Presence.untrack(self(), topic, presence_key)

        _ ->
          :error
      end

    {:reply, result, socket}
  end

  def handle_in(_, _, socket) do
    {:noreply, socket}
  end
end
