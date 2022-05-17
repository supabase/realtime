defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel
  require Logger
  import RealtimeWeb.ChannelsAuthorization, only: [authorize_conn: 2]
  alias Extensions.Postgres
  alias RealtimeWeb.{Endpoint, Presence}

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        params,
        %{
          assigns: %{
            tenant: tenant,
            claims: claims,
            limits: limits,
            postgres_extension: postgres_extension
          },
          transport_pid: pid,
          serializer: serializer
        } = socket
      ) do
    if Realtime.UsersCounter.tenant_users(tenant) < limits.max_concurrent_users do
      Realtime.UsersCounter.add(pid, tenant)
      # used for custom monitoring
      channel_stats(pid, tenant, topic)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      id = UUID.uuid1()

      postgres_topic = topic_from_config(params)
      Logger.warning("Postgres_topic is " <> postgres_topic)

      postgres_config =
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

          Logger.warning("Postgres config is #{inspect(postgres_extension, pretty: true)}")

          send(self(), :postgres_subscribe)

          postgres_config
        else
          nil
        end

      Logger.debug("Start channel, #{inspect([id: id], pretty: true)}")

      send(self(), :after_join)

      {:ok,
       assign(socket, %{
         id: id,
         postgres_config: postgres_config,
         tenant_topic: tenant_topic,
         postgres_topic: postgres_topic,
         claims: claims
       })}
    else
      Logger.error("Reached max_concurrent_users limit")
      {:error, %{reason: "reached max_concurrent_users limit"}}
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
        :postgres_subscribe,
        %{
          assigns: %{
            id: id,
            tenant: tenant,
            postgres_config: postgres_config,
            postgres_topic: postgres_topic,
            postgres_extension: postgres_extension,
            claims: claims
          }
        } = socket
      ) do
    Postgres.subscribe(
      tenant,
      id,
      postgres_config,
      claims,
      self(),
      postgres_extension
    )

    Logger.info("Subscribe #{tenant} to #{postgres_topic}")
    {:noreply, socket}
  end

  def handle_info({:DOWN, _, :process, _, _reason}, socket) do
    send(self(), :postgres_subscribe)
    {:noreply, socket}
  end

  def handle_info(other, socket) do
    Logger.error("Undefined msg #{inspect(other, pretty: true)}")
    {:noreply, socket}
  end

  @impl true
  def handle_in("access_token", %{"access_token" => nil}, socket) do
    {:noreply, socket}
  end

  def handle_in(
        "access_token",
        %{"access_token" => token},
        %{
          assigns: %{
            jwt_secret: jwt_secret,
            tenant: tenant,
            id: id
          }
        } = socket
      ) do
    case authorize_conn(token, jwt_secret) do
      {:ok, %{"exp" => expiration} = claims} ->
        if expiration < System.system_time(:second) do
          Logger.error("The client tries to refresh the expired access_token")
          {:stop, %{reason: "the client tries to refresh the expired access_token"}, socket}
        else
          Postgres.unsubscribe(tenant, UUID.string_to_binary!(id))
          new_id = UUID.uuid1()
          send(self(), :postgres_subscribe)
          {:noreply, assign(socket, %{id: new_id, claims: claims})}
        end

      _ ->
        Logger.error("Can't udpate access_token")
        {:stop, %{reason: "can't udpate access_token"}, socket}
    end
  end

  def handle_in("broadcast" = type, payload, %{assigns: %{tenant_topic: topic}} = socket) do
    Endpoint.broadcast_from(self(), topic, type, payload)
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

  defp topic_from_config(params) do
    case params["configs"]["realtime"]["filter"] do
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
end
