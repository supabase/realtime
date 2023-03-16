defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel

  require Logger

  alias DBConnection.Backoff
  alias Phoenix.Tracker.Shard
  alias RealtimeWeb.{ChannelsAuthorization, Endpoint, Presence}
  alias Realtime.{GenCounter, RateCounter, PostgresCdc, SignalHandler, Tenants}

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  defmodule Assigns do
    @moduledoc false
    defstruct [
      :tenant,
      :log_level,
      :rate_counter,
      :limits,
      :tenant_topic,
      :pg_sub_ref,
      :pg_change_params,
      :postgres_extension,
      :claims,
      :jwt_secret,
      :tenant_token,
      :access_token,
      :postgres_cdc_module,
      :channel_name
    ]

    @type t :: %__MODULE__{
            tenant: String.t(),
            log_level: atom(),
            rate_counter: RateCounter.t(),
            limits: %{
              max_events_per_second: integer(),
              max_concurrent_users: integer(),
              max_bytes_per_second: integer(),
              max_channels_per_client: integer(),
              max_joins_per_second: integer()
            },
            tenant_topic: String.t(),
            pg_sub_ref: reference() | nil,
            pg_change_params: map(),
            postgres_extension: map(),
            claims: map(),
            jwt_secret: String.t(),
            tenant_token: String.t(),
            access_token: String.t(),
            channel_name: String.t()
          }
  end

  @confirm_token_ms_interval 1_000 * 60 * 5

  @impl true
  def join(
        "realtime:" <> sub_topic = topic,
        params,
        %{
          assigns: %{
            tenant: tenant,
            log_level: log_level,
            postgres_cdc_module: module
          },
          channel_pid: channel_pid,
          serializer: serializer,
          transport_pid: transport_pid
        } = socket
      ) do
    Logger.metadata(external_id: tenant, project: tenant)
    Logger.put_process_level(self(), log_level)

    socket = socket |> assign_access_token(params) |> assign_counter()

    start_db_rate_counter(tenant)

    with false <- SignalHandler.shutdown_in_progress?(),
         :ok <- limit_joins(socket),
         :ok <- limit_channels(socket),
         :ok <- limit_max_users(socket),
         {:ok, claims, confirm_token_ref} <- confirm_token(socket) do
      Realtime.UsersCounter.add(transport_pid, tenant)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      is_new_api =
        case params do
          %{"config" => _} -> true
          _ -> false
        end

      pg_change_params =
        if is_new_api do
          send(self(), :sync_presence)

          params["config"]["postgres_changes"]
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
            ids =
              for %{id: id, params: params} <- pg_change_params do
                {UUID.string_to_binary!(id), :erlang.phash2(params)}
              end

            metadata = [
              metadata:
                {:subscriber_fastlane, transport_pid, serializer, ids, topic, tenant, is_new_api}
            ]

            # Endpoint.subscribe("realtime:postgres:" <> tenant, metadata)

            PostgresCdc.subscribe(module, pg_change_params, tenant, metadata)

            pg_change_params

          other ->
            other
        end

      Logger.debug("Postgres change params: " <> inspect(pg_change_params, pretty: true))

      if !Enum.empty?(pg_change_params) do
        send(self(), :postgres_subscribe)
      end

      Logger.debug("Start channel: " <> inspect(pg_change_params, pretty: true))

      presence_key = presence_key(params)

      {:ok,
       %{
         postgres_changes:
           Enum.map(pg_change_params, fn %{params: params} ->
             id = :erlang.phash2(params)
             Map.put(params, :id, id)
           end)
       },
       assign(socket, %{
         ack_broadcast: !!params["config"]["broadcast"]["ack"],
         confirm_token_ref: confirm_token_ref,
         is_new_api: is_new_api,
         pg_sub_ref: nil,
         pg_change_params: pg_change_params,
         presence_key: presence_key,
         self_broadcast: !!params["config"]["broadcast"]["self"],
         tenant_topic: tenant_topic,
         channel_name: sub_topic
       })}
    else
      {:error, :too_many_channels} = error ->
        error_msg = inspect(error, pretty: true)
        Logger.warn("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}

      {:error, :too_many_connections} = error ->
        error_msg = inspect(error, pretty: true)
        Logger.warn("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}

      {:error, :too_many_joins} = error ->
        error_msg = inspect(error, pretty: true)
        Logger.warn("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}

      {:error, [message: "Invalid token", claim: _claim, claim_val: _value]} = error ->
        error_msg = inspect(error, pretty: true)
        Logger.warn("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}

      error ->
        error_msg = inspect(error, pretty: true)
        Logger.error("Start channel error: #{error_msg}")
        {:error, %{reason: error_msg}}
    end
  end

  def handle_info(
        _any,
        %{
          assigns: %{
            rate_counter: %{avg: avg},
            limits: %{max_events_per_second: max}
          }
        } = socket
      )
      when avg > max do
    message = "Too many messages per second"

    shutdown_response(socket, message)
  end

  @impl true
  def handle_info(:sync_presence, %{assigns: %{tenant_topic: topic}} = socket) do
    socket = count(socket)

    push(socket, "presence_state", presence_dirty_list(topic))

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "postgres_cdc_down"}, socket) do
    pg_sub_ref = postgres_subscribe()

    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  @impl true
  def handle_info(%{event: type, payload: payload}, socket) do
    socket = count(socket)

    push(socket, type, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        :postgres_subscribe,
        %{
          assigns: %{
            tenant: tenant,
            pg_sub_ref: pg_sub_ref,
            pg_change_params: pg_change_params,
            postgres_extension: postgres_extension,
            channel_name: channel_name,
            postgres_cdc_module: module
          }
        } = socket
      ) do
    cancel_timer(pg_sub_ref)

    args = Map.put(postgres_extension, "id", tenant)

    case PostgresCdc.connect(module, args) do
      {:ok, response} ->
        case PostgresCdc.after_connect(module, response, postgres_extension, pg_change_params) do
          {:ok, _response} ->
            message = "Subscribed to PostgreSQL"

            Logger.info(message)

            push_system_message("postgres_changes", socket, "ok", message, channel_name)

            {:noreply, assign(socket, :pg_sub_ref, nil)}

          error ->
            message = "Subscribing to PostgreSQL failed: #{inspect(error)}"

            push_system_message("postgres_changes", socket, "error", message, channel_name)

            Logger.error(message)

            {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
        end

      nil ->
        Logger.warning("Re-subscribed to PostgreSQL with params: #{inspect(pg_change_params)}")
        {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe())}
    end
  end

  @impl true
  def handle_info(:confirm_token, %{assigns: %{pg_change_params: pg_change_params}} = socket) do
    case confirm_token(socket) do
      {:ok, claims, confirm_token_ref} ->
        pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))

        {:noreply,
         assign(socket, %{
           confirm_token_ref: confirm_token_ref,
           pg_change_params: pg_change_params
         })}

      {:error, error} ->
        message = "access token has expired: " <> inspect(error, pretty: true)

        shutdown_response(socket, message)
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

  @impl true
  def handle_in(
        _,
        _,
        %{
          assigns: %{
            rate_counter: %{avg: avg},
            limits: %{max_events_per_second: max}
          }
        } = socket
      )
      when avg > max do
    message = "Too many messages per second"

    shutdown_response(socket, message)
  end

  def handle_in(
        "access_token",
        %{"access_token" => refresh_token},
        %{assigns: %{pg_sub_ref: pg_sub_ref, pg_change_params: pg_change_params}} = socket
      )
      when is_binary(refresh_token) do
    socket = socket |> assign(:access_token, refresh_token)

    case confirm_token(socket) do
      {:ok, claims, confirm_token_ref} ->
        cancel_timer(pg_sub_ref)

        pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))

        pg_sub_ref =
          case pg_change_params do
            [_ | _] -> postgres_subscribe()
            _ -> nil
          end

        {:noreply,
         assign(socket, %{
           confirm_token_ref: confirm_token_ref,
           pg_change_params: pg_change_params,
           pg_sub_ref: pg_sub_ref
         })}

      {:error, error} ->
        message = "Received an invalid access token from client: " <> inspect(error)

        shutdown_response(socket, message)
    end
  end

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
    socket = count(socket)

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

  def handle_in(
        "presence",
        %{"event" => event} = payload,
        %{assigns: %{is_new_api: true, presence_key: presence_key, tenant_topic: tenant_topic}} =
          socket
      ) do
    socket = count(socket)

    result =
      event
      |> String.downcase()
      |> case do
        "track" ->
          payload = Map.get(payload, "payload", %{})

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

  def handle_in(_, _, socket) do
    socket = count(socket)
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

  def limit_joins(%{assigns: %{tenant: tenant, limits: limits}}) do
    id = Tenants.joins_per_second_key(tenant)
    GenCounter.new(id)

    RateCounter.new(id,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :joins],
        measurements: %{limit: limits.max_joins_per_second},
        metadata: %{tenant: tenant}
      }
    )

    GenCounter.add(id)

    case RateCounter.get(id) do
      {:ok, %{avg: avg}} ->
        if avg < limits.max_joins_per_second do
          :ok
        else
          {:error, :too_many_joins}
        end

      other ->
        Logger.error("Unexpected error for #{tenant} #{inspect(other)}")
        {:error, other}
    end
  end

  def limit_channels(%{assigns: %{tenant: tenant, limits: limits}, transport_pid: pid}) do
    key = Tenants.channels_per_client_key(tenant)

    if Registry.count_match(Realtime.Registry, key, pid) > limits.max_channels_per_client do
      {:error, :too_many_channels}
    else
      Registry.register(Realtime.Registry, Tenants.channels_per_client_key(tenant), pid)
      :ok
    end
  end

  defp limit_max_users(%{
         assigns: %{limits: %{max_concurrent_users: max_conn_users}, tenant: tenant}
       }) do
    conns = Realtime.UsersCounter.tenant_users(tenant)

    if conns < max_conn_users do
      :ok
    else
      {:error, :too_many_connections}
    end
  end

  defp assign_counter(%{assigns: %{tenant: tenant, limits: limits}} = socket) do
    key = Tenants.events_per_second_key(tenant)

    GenCounter.new(key)

    RateCounter.new(key,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :events],
        measurements: %{limit: limits.max_events_per_second},
        metadata: %{tenant: tenant}
      }
    )

    {:ok, rate_counter} = RateCounter.get(key)

    assign(socket, :rate_counter, rate_counter)
  end

  defp assign_counter(socket) do
    socket
  end

  defp count(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)

    assign(socket, :rate_counter, rate_counter)
  end

  defp presence_key(params) do
    with key when is_binary(key) <- params["config"]["presence"]["key"],
         true <- String.length(key) > 0 do
      key
    else
      _ -> UUID.uuid1()
    end
  end

  defp assign_access_token(%{assigns: %{tenant_token: _tenant_token}} = socket, %{
         "user_token" => user_token
       })
       when is_binary(user_token) do
    assign(socket, :access_token, user_token)
  end

  defp assign_access_token(%{assigns: %{tenant_token: _tenant_token}} = socket, %{
         "access_token" => user_token
       })
       when is_binary(user_token) do
    assign(socket, :access_token, user_token)
  end

  defp assign_access_token(%{assigns: %{tenant_token: tenant_token}} = socket, _params)
       when is_binary(tenant_token) do
    assign(socket, :access_token, tenant_token)
  end

  defp confirm_token(%{
         assigns:
           %{
             jwt_secret: jwt_secret,
             access_token: access_token
           } = assigns
       }) do
    with jwt_secret_dec <- decrypt_jwt_secret(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time() do
      if ref = assigns[:confirm_token_ref], do: cancel_timer(ref)

      ref =
        Process.send_after(
          self(),
          :confirm_token,
          min(@confirm_token_ms_interval, exp_diff * 1_000)
        )

      {:ok, claims, ref}
    else
      {:error, e} ->
        {:error, e}

      e ->
        {:error, e}
    end
  end

  defp shutdown_response(%{assigns: %{channel_name: channel_name}} = socket, message)
       when is_binary(message) do
    push_system_message("system", socket, "error", message, channel_name)

    Logger.error(message)

    {:stop, :shutdown, socket}
  end

  defp push_system_message(extension, socket, status, message, channel_name) do
    push(socket, "system", %{
      extension: extension,
      status: status,
      message: message,
      channel: channel_name
    })
  end

  def presence_dirty_list(topic) do
    [{:pool_size, size}] = :ets.lookup(Presence, :pool_size)

    Presence
    |> Shard.name_for_topic(topic, size)
    |> Shard.dirty_list(topic)
    |> Phoenix.Presence.group()
  end

  defp start_db_rate_counter(tenant) do
    key = Tenants.db_events_per_second_key(tenant)
    GenCounter.new(key)

    RateCounter.new(key,
      idle_shutdown: :infinity,
      telemetry: %{
        event_name: [:channel, :db_events],
        measurements: %{},
        metadata: %{tenant: tenant}
      }
    )
  end
end
