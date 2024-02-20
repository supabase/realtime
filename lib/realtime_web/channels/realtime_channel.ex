defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel

  require Logger

  alias DBConnection.Backoff

  alias Phoenix.Tracker.Shard

  alias Realtime.GenCounter
  alias Realtime.Helpers
  alias Realtime.PostgresCdc
  alias Realtime.RateCounter
  alias Realtime.SignalHandler
  alias Realtime.Tenants
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.Presence
  alias RealtimeWeb.RealtimeChannel.BroadcastHandler
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  @confirm_token_ms_interval 1_000 * 60 * 5

  @impl true
  def join("realtime:" <> sub_topic = topic, params, socket) do
    %{
      assigns: %{tenant: tenant, log_level: log_level, postgres_cdc_module: module},
      channel_pid: channel_pid,
      serializer: serializer,
      transport_pid: transport_pid
    } = socket

    Logger.metadata(external_id: tenant, project: tenant)
    Logger.put_process_level(self(), log_level)

    socket =
      socket
      |> assign_access_token(params)
      |> assign_counter()

    start_db_rate_counter(tenant)

    with false <- SignalHandler.shutdown_in_progress?(),
         :ok <- limit_joins(socket.assigns),
         :ok <- limit_channels(socket),
         :ok <- limit_max_users(socket.assigns),
         {:ok, claims, confirm_token_ref} <- confirm_token(socket),
         {:ok, _} <- Connect.lookup_or_start_connection(tenant),
         is_new_api <- is_new_api(params) do
      Realtime.UsersCounter.add(transport_pid, tenant)

      tenant_topic = tenant <> ":" <> sub_topic
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      pg_change_params = pg_change_params(is_new_api, params, channel_pid, claims, sub_topic)

      opts = %{
        is_new_api: is_new_api,
        pg_change_params: pg_change_params,
        transport_pid: transport_pid,
        serializer: serializer,
        topic: topic,
        tenant: tenant,
        module: module
      }

      postgres_cdc_subscribe(opts)

      Logger.debug("Start channel: " <> inspect(pg_change_params))

      state = %{postgres_changes: add_id_to_postgres_changes(pg_change_params)}

      assigns = %{
        ack_broadcast: !!params["config"]["broadcast"]["ack"],
        confirm_token_ref: confirm_token_ref,
        is_new_api: is_new_api,
        pg_sub_ref: nil,
        pg_change_params: pg_change_params,
        presence_key: presence_key(params),
        self_broadcast: !!params["config"]["broadcast"]["self"],
        tenant_topic: tenant_topic,
        channel_name: sub_topic
      }

      {:ok, state, assign(socket, assigns)}
    else
      {:error, [message: "Invalid token", claim: _claim, claim_val: _value]} = error ->
        log_error_message(:warning, error)

      {:error, type} = error
      when type in [:too_many_channels, :too_many_connections, :too_many_joins] ->
        log_error_message(:warning, error)

      error ->
        log_error_message(:error, error)
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
  def handle_info(:sync_presence = msg, %{assigns: %{tenant_topic: topic}} = socket) do
    # TODO: don't use Presence unless client explicitly wants to use Presence
    # TODO: count these again when that happens

    socket = maybe_log_handle_info(socket, msg)

    push(socket, "presence_state", presence_dirty_list(topic))

    {:noreply, socket}
  end

  @impl true
  def handle_info(%{event: "postgres_cdc_rls_down"}, socket) do
    pg_sub_ref = postgres_subscribe()

    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  @impl true
  def handle_info(%{event: "postgres_cdc_down"}, socket) do
    pg_sub_ref = postgres_subscribe()

    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  @impl true
  def handle_info(%{event: type, payload: payload} = msg, socket) do
    socket = socket |> count() |> maybe_log_handle_info(msg)

    push(socket, type, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:postgres_subscribe, socket) do
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

    Helpers.cancel_timer(pg_sub_ref)

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
            message = "Subscribing to PostgreSQL failed: " <> inspect(error)
            Logger.error(message)
            push_system_message("postgres_changes", socket, "error", message, channel_name)
            {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
        end

      nil ->
        Logger.warning("Re-connecting to PostgreSQL with params: " <> inspect(pg_change_params))
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
        message = "access token has expired: " <> inspect(error)

        shutdown_response(socket, message)
    end
  end

  def handle_info(msg, socket) do
    Logger.error("HANDLE_INFO message not handled: " <> inspect(msg))
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
        %{assigns: %{access_token: access_token}} = socket
      )
      when refresh_token == access_token do
    {:noreply, socket}
  end

  def handle_in(
        "access_token",
        %{"access_token" => refresh_token},
        %{assigns: %{access_token: _access_token}} = socket
      )
      when is_nil(refresh_token) do
    {:noreply, socket}
  end

  def handle_in(
        "access_token",
        %{"access_token" => refresh_token},
        %{
          assigns: %{
            access_token: _access_token,
            pg_sub_ref: pg_sub_ref,
            pg_change_params: pg_change_params
          }
        } = socket
      )
      when is_binary(refresh_token) do
    socket = assign(socket, :access_token, refresh_token)

    case confirm_token(socket) do
      {:ok, claims, confirm_token_ref} ->
        Helpers.cancel_timer(pg_sub_ref)

        pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))

        pg_sub_ref =
          case pg_change_params do
            [_ | _] -> postgres_subscribe()
            _ -> nil
          end

        assigns = %{
          pg_sub_ref: pg_sub_ref,
          confirm_token_ref: confirm_token_ref,
          pg_change_params: pg_change_params
        }

        {:noreply, assign(socket, assigns)}

      {:error, error} ->
        message = "Received an invalid access token from client: " <> inspect(error)

        shutdown_response(socket, message)
    end
  end

  def handle_in("broadcast", payload, socket) do
    BroadcastHandler.call(payload, socket)
  end

  def handle_in("presence", payload, socket) do
    PresenceHandler.call(payload, socket)
  end

  def handle_in(type, payload, socket) do
    socket = count(socket)

    # Log info here so that bad messages from clients won't flood Logflare
    # Can subscribe to a Channel with `log_level` `info` to see these messages
    message = "Unexpected message from client of type `#{type}` with payload: #{inspect(payload)}"
    Logger.info(message)

    {:noreply, socket}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("Channel terminated with reason: " <> inspect(reason))
    :telemetry.execute([:prom_ex, :plugin, :realtime, :disconnected], %{})
    :ok
  end

  defp postgres_subscribe(min \\ 1, max \\ 5) do
    Process.send_after(self(), :postgres_subscribe, backoff(min, max))
  end

  defp backoff(min, max) do
    {wait, _} = Backoff.backoff(%Backoff{type: :rand, min: min * 1000, max: max * 1000})
    wait
  end

  def limit_joins(%{tenant: tenant, limits: limits}) do
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
      {:ok, %{avg: avg}} when avg < limits.max_joins_per_second ->
        :ok

      {:ok, %{avg: _}} ->
        {:error, :too_many_joins}

      other ->
        Logger.error("Unexpected error: " <> inspect(other))

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

  defp limit_max_users(%{limits: %{max_concurrent_users: max_conn_users}, tenant: tenant}) do
    conns = Realtime.UsersCounter.tenant_users(tenant)

    if conns < max_conn_users,
      do: :ok,
      else: {:error, :too_many_connections}
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

  defp assign_counter(socket), do: socket

  defp count(%{assigns: %{rate_counter: counter}} = socket) do
    GenCounter.add(counter.id)
    {:ok, rate_counter} = RateCounter.get(counter.id)

    assign(socket, :rate_counter, rate_counter)
  end

  defp maybe_log_handle_info(
         %{assigns: %{log_level: log_level, channel_name: channel_name}} = socket,
         msg
       ) do
    if Logger.compare_levels(log_level, :error) == :lt do
      msg = "HANDLE_INFO INCOMING ON " <> channel_name <> " message: " <> inspect(msg)
      Logger.log(log_level, msg)
    end

    socket
  end

  defp presence_key(params) do
    with key when is_binary(key) and key != "" <- params["config"]["presence"]["key"] do
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

  defp confirm_token(%{assigns: %{jwt_secret: jwt_secret, access_token: access_token} = assigns}) do
    secure_key = Application.fetch_env!(:realtime, :db_enc_key)

    with jwt_secret_dec <- Helpers.decrypt!(jwt_secret, secure_key),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time() do
      if ref = assigns[:confirm_token_ref], do: Helpers.cancel_timer(ref)

      interval = min(@confirm_token_ms_interval, exp_diff * 1_000)
      ref = Process.send_after(self(), :confirm_token, interval)

      {:ok, claims, ref}
    else
      {:error, e} -> {:error, e}
      e -> {:error, e}
    end
  end

  defp shutdown_response(%{assigns: %{channel_name: channel_name}} = socket, message)
       when is_binary(message) do
    push_system_message("system", socket, "error", message, channel_name)

    Logger.error("Channel shutting down with message: " <> message)

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

  defp presence_dirty_list(topic) do
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

  defp is_new_api(%{"config" => _}), do: true
  defp is_new_api(_), do: false

  defp pg_change_params(true, params, channel_pid, claims, _) do
    send(self(), :sync_presence)

    case get_in(params, ["config", "postgres_changes"]) do
      [_ | _] = params_list ->
        Enum.map(params_list, fn params ->
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
  end

  defp pg_change_params(false, _, channel_pid, claims, sub_topic) do
    params =
      case String.split(sub_topic, ":", parts: 3) do
        [schema, table, filter] -> %{"schema" => schema, "table" => table, "filter" => filter}
        [schema, table] -> %{"schema" => schema, "table" => table}
        [schema] -> %{"schema" => schema}
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

  defp postgres_cdc_subscribe(%{pg_change_params: []}), do: []

  defp postgres_cdc_subscribe(opts) do
    %{
      is_new_api: is_new_api,
      pg_change_params: pg_change_params,
      transport_pid: transport_pid,
      serializer: serializer,
      topic: topic,
      tenant: tenant,
      module: module
    } = opts

    ids =
      Enum.map(pg_change_params, fn %{id: id, params: params} ->
        {UUID.string_to_binary!(id), :erlang.phash2(params)}
      end)

    subscription_metadata =
      {:subscriber_fastlane, transport_pid, serializer, ids, topic, tenant, is_new_api}

    metadata = [metadata: subscription_metadata]

    PostgresCdc.subscribe(module, pg_change_params, tenant, metadata)

    send(self(), :postgres_subscribe)

    pg_change_params
  end

  defp add_id_to_postgres_changes(pg_change_params) do
    Enum.map(pg_change_params, fn %{params: params} ->
      id = :erlang.phash2(params)
      Map.put(params, :id, id)
    end)
  end

  defp log_error_message(:warning, error) do
    error_msg = inspect(error)
    Logger.warn("Start channel error: " <> error_msg)
    {:error, %{reason: error_msg}}
  end

  defp log_error_message(:error, error) do
    error_msg = inspect(error)
    Logger.error("Start channel error: " <> error_msg)
    {:error, %{reason: error_msg}}
  end
end
