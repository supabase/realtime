defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel

  require Logger

  alias Extensions.Postgres
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint, Presence}

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        params,
        %{
          assigns: %{
            is_new_api: is_new_api,
            jwt_secret: jwt_secret,
            limits: %{max_concurrent_users: max_conn_users},
            tenant: tenant,
            token: token
          },
          transport_pid: pid,
          serializer: serializer
        } = socket
      ) do
    Logger.metadata(external_id: tenant, project: tenant)
    secure_key = Application.get_env(:realtime, :db_enc_key)

    with true <- Realtime.UsersCounter.tenant_users(tenant) < max_conn_users,
         access_token when is_binary(access_token) <-
           (case params do
              %{"user_token" => user_token} -> user_token
              _ -> token
            end),
         jwt_secret_dec <- decrypt!(jwt_secret, secure_key),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         expire_ref <- Process.send_after(self(), :expire_token, exp_diff * 1_000) do
      Realtime.UsersCounter.add(pid, tenant)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      id = UUID.uuid1()

      postgres_topic = topic_from_config(params)
      Logger.info("Postgres_topic is " <> postgres_topic)

      postgres_config =
        if postgres_topic != "" || !is_new_api do
          Endpoint.unsubscribe(topic)

          metadata = [
            metadata:
              {:subscriber_fastlane, pid, serializer, UUID.string_to_binary!(id), topic,
               is_new_api}
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
          send(self(), :postgres_subscribe)
          postgres_config
        else
          nil
        end

      Logger.debug("Start channel, #{inspect([id: id], pretty: true)}")

      if is_map(params) && params["configs"]["presence"] do
        send(self(), :sync_presence)
      end

      Process.put(:tenant, tenant)

      {:ok,
       assign(socket, %{
         access_token: access_token,
         claims: claims,
         expire_ref: expire_ref,
         id: id,
         postgres_topic: postgres_topic,
         postgres_config: postgres_config,
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
  def handle_info(:sync_presence, %{assigns: %{tenant_topic: topic}} = socket) do
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
          assigns:
            %{
              id: id,
              tenant: tenant,
              postgres_config: postgres_config,
              postgres_topic: postgres_topic,
              postgres_extension: postgres_extension,
              claims: claims
            } = assigns
        } = socket
      ) do
    cancel_timer(assigns[:pg_sub_ref])

    Postgres.subscribe(
      tenant,
      id,
      postgres_config,
      claims,
      self(),
      postgres_extension
    )
    |> case do
      {:ok, manager_pid} ->
        Logger.info("Subscribe channel for #{tenant} to #{postgres_topic}")
        Process.monitor(manager_pid)
        {:noreply, socket}

      :ok ->
        Logger.warning("Re-subscribe channel for #{tenant}")
        ref = Process.send_after(self(), :postgres_subscribe, 5_000)
        {:noreply, assign(socket, :pg_sub_ref, ref)}

      {:error, error} ->
        Logger.error(
          "Failed to subscribe channel for #{tenant} to #{postgres_topic}: #{inspect(error)}"
        )

        {:stop, %{reason: error}, socket}
    end
  end

  def handle_info(
        :expire_token,
        %{assigns: %{expire_ref: ref}} = socket
      ) do
    cancel_timer(ref)
    {:stop, %{reason: "access token has expired"}, socket}
  end

  def handle_info(
        {:DOWN, _, :process, _, _reason},
        %{assigns: %{postgres_config: postgres_config}} = socket
      ) do
    unless is_nil(postgres_config) do
      send(self(), :postgres_subscribe)
    end

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
        %{"access_token" => refresh_token},
        %{
          assigns: %{
            expire_ref: ref,
            id: id,
            jwt_secret: jwt_secret,
            postgres_config: postgres_config
          }
        } = socket
      )
      when is_binary(refresh_token) do
    cancel_timer(ref)

    with {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(refresh_token, jwt_secret),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         expire_ref <- Process.send_after(self(), :expire_token, exp_diff * 1_000) do
      unless is_nil(postgres_config) do
        send(self(), :postgres_subscribe)
      end

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
