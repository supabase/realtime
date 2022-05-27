defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel

  require Logger

  alias Extensions.Postgres
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint, Presence}

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        params,
        %{
          assigns: %{
            jwt_secret: jwt_secret,
            tenant: tenant,
            limits: %{max_concurrent_users: max_conn_users},
            token: token
          },
          transport_pid: pid,
          serializer: serializer
        } = socket
      ) do
    with true <- Realtime.UsersCounter.tenant_users(tenant) < max_conn_users,
         access_token when is_binary(access_token) <-
           (case params do
              %{"user_token" => user_token} -> user_token
              _ -> token
            end),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         expire_ref <- Process.send_after(self(), :expire_token, exp_diff * 1_000) do
      Realtime.UsersCounter.add(pid, tenant)
      # used for custom monitoring
      channel_stats(pid, tenant, topic)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      id = UUID.uuid1()

      postgres_topic = topic_from_config(params)
      Logger.info("Postgres_topic is " <> postgres_topic)

      if postgres_topic != "" || !params["configs"]["realtime"] do
        Endpoint.unsubscribe(topic)

        metadata = [
          metadata: {:subscriber_fastlane, pid, serializer, UUID.string_to_binary!(id), topic}
        ]

        Endpoint.subscribe("realtime:postgres:" <> tenant, metadata)

        postgres_config =
          case params["configs"]["realtime"]["filter"] do
            nil ->
              case String.split(sub_topic, ":") do
                [schema] ->
                  %{"schema" => schema}

                [schema, table] ->
                  %{"schema" => schema, "table" => table}

                [schema, table, filter] ->
                  %{"schema" => schema, "table" => table, "filter" => filter}
              end

            config ->
              config
          end

        Logger.debug("Postgres config is #{inspect(postgres_config, pretty: true)}")

        Postgres.subscribe(
          tenant,
          id,
          postgres_config,
          claims,
          self()
        )
      end

      Logger.debug("Start channel, #{inspect([id: id], pretty: true)}")

      send(self(), :after_join)

      {:ok,
       assign(socket, %{
         access_token: access_token,
         claims: claims,
         expire_ref: expire_ref,
         id: id,
         postgres_topic: postgres_topic,
         self_broadcast: is_map(params) && params["self_broadcast"] == true,
         tenant_topic: tenant_topic
       })}
    else
      error ->
        error_msg = inspect(error, pretty: true)
        Logger.error("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}
    end
  end

  @impl true
  def handle_info(:after_join, %{assigns: %{tenant_topic: topic}} = socket) do
    push(socket, "presence_state", Presence.list(topic))
    {:noreply, socket}
  end

  def handle_info(%{event: type, payload: payload}, socket) do
    push(socket, type, payload)
    {:noreply, socket}
  end

  def handle_info(
        :postgres_resubscribe,
        %{
          assigns: %{
            id: id,
            tenant: tenant,
            postgres_topic: postgres_topic,
            claims: claims
          }
        } = socket
      ) do
    Postgres.subscribe(tenant, id, postgres_topic, claims, self())
    Logger.info("Re-subscribed #{tenant} to #{postgres_topic}")
    {:noreply, socket}
  end

  def handle_info(
        :expire_token,
        %{assigns: %{expire_ref: ref}} = socket
      ) do
    Process.cancel_timer(ref)
    {:stop, %{reason: "access token has expired"}, socket}
  end

  def handle_info(other, socket) do
    Logger.error("Undefined msg #{inspect(other, pretty: true)}")
    {:noreply, socket}
  end

  def handle_in(
        "access_token",
        %{"access_token" => refresh_token},
        %{
          assigns: %{
            expire_ref: ref,
            id: id,
            jwt_secret: jwt_secret,
            postgres_topic: postgres_topic,
            tenant: tenant
          }
        } = socket
      )
      when is_binary(refresh_token) do
    Process.cancel_timer(ref)

    with {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(refresh_token, jwt_secret),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         expire_ref <- Process.send_after(self(), :expire_token, exp_diff * 1_000) do
      Postgres.subscribe(tenant, id, postgres_topic, claims, self())
      {:noreply, assign(socket, %{claims: claims, id: id, expire_ref: expire_ref})}
    else
      _ -> {:stop, %{reason: "received an invalid access token from client"}, socket}
    end
  end

  @impl true
  def handle_in("access_token", _, socket) do
    {:noreply, socket}
  end

  def handle_in(
        "broadcast" = type,
        payload,
        %{assigns: %{self_broadcast: self_broadcast, tenant_topic: topic}} = socket
      ) do
    if self_broadcast do
      Endpoint.broadcast(topic, type, payload)
    else
      Endpoint.broadcast_from(self(), topic, type, payload)
    end

    {:noreply, socket}
  end

  def handle_in(
        "presence",
        %{"event" => "TRACK", "payload" => payload} = msg,
        %{assigns: %{id: id, tenant_topic: topic}} = socket
      ) do
    case Presence.track(self(), topic, Map.get(msg, "key", id), payload) do
      {:ok, _} ->
        :ok

      {:error, {:already_tracked, _, _, _}} ->
        Presence.update(self(), topic, Map.get(msg, "key", id), payload)
    end

    {:reply, :ok, socket}
  end

  def handle_in(
        "presence",
        %{"event" => "UNTRACK"} = msg,
        %{assigns: %{id: id, tenant_topic: topic}} = socket
      ) do
    Presence.untrack(self(), topic, Map.get(msg, "key", id))

    {:reply, :ok, socket}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :realtime, :disconnected], %{})
    :ok
  end

  def channel_stats(pid, tenant, topic) do
    Registry.register(
      Realtime.Registry,
      "topics",
      {tenant, topic, System.system_time(:second)}
    )

    Registry.register(
      Realtime.Registry.Unique,
      "sessions",
      {pid, System.system_time(:second)}
    )
  end

  defp topic_from_config(params) when is_map(params) do
    case get_in(params, ["configs", "realtime", "filter"]) do
      %{"schema" => schema, "table" => table, "filter" => filter} ->
        "#{schema}:#{table}:#{filter}"

      %{"schema" => schema, "table" => table} ->
        "#{schema}:#{table}"

      %{"schema" => schema} ->
        "#{schema}"

      _ ->
        ""
    end
  end

  defp topic_from_config(_), do: ""
end
