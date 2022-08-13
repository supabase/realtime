defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel

  require Logger

  alias DBConnection.Backoff
  alias Extensions.Postgres
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint, Presence}
  alias Realtime.{GenCounter, RateCounter}

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  @confirm_token_ms_interval 1_000 * 60 * 5
  @max_join_rate 100
  @max_user_channels 15

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        params,
        %{
          assigns: %{
            jwt_secret: jwt_secret,
            limits: %{max_concurrent_users: max_conn_users},
            tenant: tenant,
            token: token
          },
          channel_pid: channel_pid,
          serializer: serializer,
          transport_pid: transport_pid
        } = socket
      ) do
    Logger.metadata(external_id: tenant, project: tenant)

    with :ok <- limit_joins(socket),
         :ok <- limit_channels(socket),
         true <- Realtime.UsersCounter.tenant_users(tenant) < max_conn_users,
         access_token when is_binary(access_token) <-
           (case params do
              %{"user_token" => user_token} -> user_token
              _ -> token
            end),
         jwt_secret_dec <- decrypt_jwt_secret(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         confirm_token_ref <-
           Process.send_after(
             self(),
             :confirm_token,
             min(@confirm_token_ms_interval, exp_diff * 1_000)
           ) do
      Realtime.UsersCounter.add(transport_pid, tenant)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      is_new_api =
        case params do
          %{"configs" => _} -> true
          _ -> false
        end

      pg_change_params =
        if is_new_api do
          send(self(), :sync_presence)

          params["configs"]["postgres_changes"]
          |> case do
            [_ | _] = params_list ->
              params_list
              |> Enum.map(fn params ->
                %{
                  id: UUID.uuid1(),
                  channel_pid: channel_pid,
                  claims: claims,
                  params: params
                }
              end)

            _ ->
              []
          end
        else
          params =
            case String.split(sub_topic, ":", parts: 3) do
              [schema, table, filter] ->
                %{"schema" => schema, "table" => table, "filter" => filter}

              [schema, table] ->
                %{"schema" => schema, "table" => table}

              [schema] ->
                %{"schema" => schema}
            end

          [
            %{
              id: UUID.uuid1(),
              channel_pid: channel_pid,
              claims: claims,
              params: params
            }
          ]
        end
        |> case do
          [_ | _] = pg_change_params ->
            metadata = [
              metadata:
                {:subscriber_fastlane, transport_pid, serializer,
                 Enum.map(pg_change_params, &(&1 |> Map.fetch!(:id) |> UUID.string_to_binary!())),
                 topic, is_new_api}
            ]

            Endpoint.subscribe("realtime:postgres:" <> tenant, metadata)

            pg_change_params

          other ->
            other
        end

      Logger.info("Postgres change params: " <> inspect(pg_change_params))

      pg_sub_ref =
        case pg_change_params do
          [_ | _] -> postgres_subscribe()
          _ -> nil
        end

      Logger.debug("Start channel, #{inspect(pg_change_params, pretty: true)}")

      presence_key =
        with key when is_binary(key) <- params["configs"]["presence"]["key"],
             true <- String.length(key) > 0 do
          key
        else
          _ -> UUID.uuid1()
        end

      {:ok,
       %{
         postgres_changes:
           Enum.map(pg_change_params, fn %{id: id, params: params} ->
             Map.put(params, :id, id)
           end)
       },
       assign(socket, %{
         access_token: access_token,
         ack_broadcast: !!params["configs"]["broadcast"]["ack"],
         confirm_token_ref: confirm_token_ref,
         is_new_api: is_new_api,
         pg_sub_ref: pg_sub_ref,
         pg_change_params: pg_change_params,
         presence_key: presence_key,
         self_broadcast: !!params["configs"]["broadcast"]["self"],
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

  def handle_info(%{event: "subscription_manager_down"}, socket) do
    pg_sub_ref = postgres_subscribe()
    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  def handle_info(%{event: type, payload: payload}, socket) do
    push(socket, type, payload)
    {:noreply, socket}
  end

  def handle_info(
        :postgres_subscribe,
        %{
          assigns: %{
            tenant: tenant,
            pg_sub_ref: pg_sub_ref,
            pg_change_params: pg_change_params,
            postgres_extension: postgres_extension,
            tenant_topic: tenant_topic
          }
        } = socket
      ) do
    cancel_timer(pg_sub_ref)

    args = Map.put(postgres_extension, "id", tenant)

    case Postgres.get_or_start_conn(args) do
      {:ok, manager_pid, conn} ->
        Logger.info("Subscribe channel for #{tenant} to #{inspect(pg_change_params)}")

        case Postgres.create_subscription(
               conn,
               postgres_extension["publication"],
               pg_change_params,
               15_000
             ) do
          {:ok, _response} ->
            Endpoint.subscribe("subscription_manager:" <> tenant)

            for %{id: id} <- pg_change_params do
              send(manager_pid, {:subscribed, {self(), id}})
            end

            push(socket, "system", %{
              status: "ok",
              message: "subscribed to realtime",
              topic: tenant_topic
            })

            {:noreply, assign(socket, :pg_sub_ref, nil)}

          error ->
            push(socket, "system", %{
              status: "error",
              message: "failed to subscribe channel",
              topic: tenant_topic
            })

            Logger.error(
              "Failed to subscribe channel for #{tenant} to #{inspect(pg_change_params)}: #{inspect(error)}"
            )

            {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
        end

      nil ->
        Logger.warning("Re-subscribe channel for #{tenant} to #{inspect(pg_change_params)}")
        {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe())}
    end
  end

  def handle_info(
        :confirm_token,
        %{
          assigns: %{
            confirm_token_ref: ref,
            jwt_secret: jwt_secret,
            access_token: access_token,
            pg_change_params: pg_change_params
          }
        } = socket
      ) do
    cancel_timer(ref)

    with jwt_secret_dec <- decrypt_jwt_secret(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         confirm_token_ref <-
           Process.send_after(
             self(),
             :confirm_token,
             min(@confirm_token_ms_interval, exp_diff * 1_000)
           ) do
      pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))

      {:noreply,
       assign(socket, %{confirm_token_ref: confirm_token_ref, pg_change_params: pg_change_params})}
    else
      _ -> {:stop, %{reason: "access token has expired"}, socket}
    end
  end

  def handle_info(
        {:DOWN, _, :process, _, _reason},
        %{assigns: %{pg_sub_ref: pg_sub_ref, pg_change_params: pg_change_params}} = socket
      ) do
    cancel_timer(pg_sub_ref)

    ref =
      case pg_change_params do
        [_ | _] -> postgres_subscribe()
        _ -> nil
      end

    {:noreply, assign(socket, :pg_sub_ref, ref)}
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
            confirm_token_ref: ref,
            id: id,
            jwt_secret: jwt_secret,
            pg_sub_ref: pg_sub_ref,
            pg_change_params: pg_change_params
          }
        } = socket
      )
      when is_binary(refresh_token) do
    cancel_timer(ref)

    with jwt_secret_dec <- decrypt_jwt_secret(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(refresh_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         confirm_token_ref <-
           Process.send_after(
             self(),
             :confirm_token,
             min(@confirm_token_ms_interval, exp_diff * 1_000)
           ) do
      cancel_timer(pg_sub_ref)

      pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))

      pg_sub_ref =
        case pg_change_params do
          [_ | _] -> postgres_subscribe()
          _ -> nil
        end

      {:noreply,
       assign(socket, %{
         access_token: refresh_token,
         confirm_token_ref: confirm_token_ref,
         id: id,
         pg_change_params: pg_change_params,
         pg_sub_ref: pg_sub_ref
       })}
    else
      _ -> {:stop, %{reason: "received an invalid access token from client"}, socket}
    end
  end

  @impl true
  def handle_in(
        "broadcast" = type,
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
    if self_broadcast do
      Endpoint.broadcast(tenant_topic, type, payload)
    else
      Endpoint.broadcast_from(self(), tenant_topic, type, payload)
    end

    if ack_broadcast do
      {:reply, :ok, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_in(
        "presence",
        %{"event" => event, "payload" => payload},
        %{assigns: %{is_new_api: true, presence_key: presence_key, tenant_topic: tenant_topic}} =
          socket
      ) do
    result =
      event
      |> String.downcase()
      |> case do
        "track" ->
          with {:error, {:already_tracked, _, _, _}} <-
                 Presence.track(self(), tenant_topic, presence_key, payload),
               {:ok, _} <- Presence.update(self(), tenant_topic, presence_key, payload) do
            :ok
          else
            {:ok, _} -> :ok
            {:error, _} -> :error
          end

        "untrack" ->
          Presence.untrack(self(), tenant_topic, presence_key)

        _ ->
          :error
      end

    {:reply, result, socket}
  end

  @impl true
  def handle_in(_, _, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug(%{terminate: reason})
    :telemetry.execute([:prom_ex, :plugin, :realtime, :disconnected], %{})
    :ok
  end

  defp decrypt_jwt_secret(secret) do
    secure_key = Application.get_env(:realtime, :db_enc_key)
    decrypt!(secret, secure_key)
  end

  defp postgres_subscribe(min \\ 1, max \\ 5) do
    Process.send_after(self(), :postgres_subscribe, backoff(min, max))
  end

  defp backoff(min, max) do
    {wait, _} = Backoff.backoff(%Backoff{type: :rand, min: min * 1000, max: max * 1000})
    wait
  end

  def limit_joins(%{assigns: %{tenant: tenant}}) do
    id = {:limit, :channel_joins, tenant}
    GenCounter.new(id)
    RateCounter.new(id, idle_shutdown: :infinity)
    GenCounter.add(id)

    case RateCounter.get(id) do
      {:ok, %{avg: avg}} ->
        if avg < @max_join_rate do
          :ok
        else
          Logger.error("Rate limit exceeded for #{tenant} #{avg}")
          {:error, :too_many_joins}
        end

      other ->
        Logger.error("Unexpected error for #{tenant} #{inspect(other)}")
        {:error, other}
    end
  end

  def limit_channels(%{assigns: %{tenant: tenant}, transport_pid: pid}) do
    key = limit_channels_key(tenant)

    if Registry.count_match(Realtime.Registry, key, pid) > @max_user_channels do
      Logger.error("Reached the limit of channels per connection for #{tenant}")
      {:error, :too_many_channels}
    else
      Registry.register(Realtime.Registry, limit_channels_key(tenant), pid)
      :ok
    end
  end

  defp limit_channels_key(tenant) do
    {:limit, :user_channels, tenant}
  end
end
