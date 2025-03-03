defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel
  require Logger
  import Realtime.Logs

  alias DBConnection.Backoff

  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.Helpers
  alias Realtime.PostgresCdc
  alias Realtime.RateCounter
  alias Realtime.SignalHandler
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.RealtimeChannel.BroadcastHandler
  alias RealtimeWeb.RealtimeChannel.Logging
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  @confirm_token_ms_interval :timer.minutes(5)

  @impl true
  def join("realtime:", _params, _socket) do
    Logging.log_error_message(:error, "TopicNameRequired", "You must provide a topic name")
  end

  def join("realtime:" <> sub_topic = topic, params, socket) do
    %{
      assigns: %{tenant: tenant_id, log_level: log_level, postgres_cdc_module: module},
      channel_pid: channel_pid,
      serializer: serializer,
      transport_pid: transport_pid
    } = socket

    Logger.metadata(external_id: tenant_id, project: tenant_id)
    Logger.put_process_level(self(), log_level)

    socket =
      socket
      |> assign_access_token(params)
      |> assign_counter()
      |> assign(:using_broadcast?, !!params["config"]["broadcast"])
      |> assign(:private?, !!params["config"]["private"])
      |> assign(:policies, nil)

    start_db_rate_counter(tenant_id)

    with :ok <- SignalHandler.shutdown_in_progress?(),
         :ok <- only_private?(tenant_id, socket),
         :ok <- limit_joins(socket.assigns),
         :ok <- limit_channels(socket),
         :ok <- limit_max_users(socket.assigns),
         {:ok, claims, confirm_token_ref, access_token, _} <- confirm_token(socket),
         {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id),
         socket = assign_authorization_context(socket, sub_topic, access_token, claims),
         {:ok, socket} <- maybe_assign_policies(sub_topic, db_conn, socket) do
      tenant_topic = Tenants.tenant_topic(tenant_id, sub_topic, !socket.assigns.private?)
      Realtime.UsersCounter.add(transport_pid, tenant_id)
      RealtimeWeb.Endpoint.subscribe(tenant_topic)
      Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_id)

      is_new_api = new_api?(params)
      pg_change_params = pg_change_params(is_new_api, params, channel_pid, claims, sub_topic)

      opts = %{
        is_new_api: is_new_api,
        pg_change_params: pg_change_params,
        transport_pid: transport_pid,
        serializer: serializer,
        topic: topic,
        tenant: tenant_id,
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
        channel_name: sub_topic,
        db_conn: db_conn
      }

      {:ok, state, assign(socket, assigns)}
    else
      {:error, :expired_token, msg} ->
        Logging.log_error_message(:error, "InvalidJWTToken", msg)

      {:error, :missing_claims} ->
        msg = "Fields `role` and `exp` are required in JWT"
        Logging.log_error_message(:error, "InvalidJWTToken", msg)

      {:error, :expected_claims_map} ->
        msg = "Token claims must be a map"
        Logging.log_error_message(:error, "InvalidJWTToken", msg)

      {:error, :unauthorized, msg} ->
        Logging.log_error_message(:warning, "Unauthorized", msg)

      {:error, :too_many_channels} ->
        msg = "Too many channels"
        Logging.log_error_message(:error, "ChannelRateLimitReached", msg)

      {:error, :too_many_connections} ->
        msg = "Too many connected users"
        Logging.log_error_message(:error, "ConnectionRateLimitReached", msg)

      {:error, :too_many_joins} ->
        msg = "Too many joins per second"
        Logging.log_error_message(:error, "ClientJoinRateLimitReached", msg)

      {:error, :increase_connection_pool} ->
        msg = "Please increase your connection pool size"
        Logging.log_error_message(:warning, "IncreaseConnectionPool", msg)

      {:error, :tenant_db_too_many_connections} ->
        msg = "Database can't accept more connections, Realtime won't connect"
        Logging.log_error_message(:warning, "DatabaseLackOfConnections", msg)

      {:error, :unable_to_set_policies, error} ->
        Logging.log_error_message(:warning, "UnableToSetPolicies", error)

      {:error, :tenant_database_unavailable} ->
        Logging.log_error_message(
          :error,
          "UnableToConnectToProject",
          "Realtime was unable to connect to the project database"
        )

      {:error, :rpc_error, :timeout} ->
        Logging.log_error_message(:error, "TimeoutOnRpcCall", "Node request timeout")

      {:error, :rpc_error, reason} ->
        Logging.log_error_message(:error, "ErrorOnRpcCall", "RPC call error: " <> inspect(reason))

      {:error, :initializing} ->
        Logging.log_error_message(
          :error,
          "InitializingProjectConnection",
          "Realtime is initializing the project connection"
        )

      {:error, :tenant_database_connection_initializing} ->
        Logging.log_error_message(
          :warning,
          "InitializingProjectConnection",
          "Connecting to the project database"
        )

      {:error, invalid_exp} when is_integer(invalid_exp) and invalid_exp <= 0 ->
        Logging.log_error_message(
          :error,
          "InvalidJWTExpiration",
          "Token expiration time is invalid"
        )

      {:error, :private_only} ->
        Logging.log_error_message(
          :error,
          "PrivateOnly",
          "This project only allows private channels"
        )

      {:error, :signature_error} ->
        Logging.log_error_message(:error, "JwtSignatureError", "Failed to validate JWT signature")

      {:error, :shutdown_in_progress} ->
        Logging.log_error_message(
          :error,
          "RealtimeRestarting",
          "Realtime is restarting, please standby"
        )

      {:error, error} ->
        Logging.log_error_message(:error, "UnknownErrorOnChannel", error)
    end
  end

  @impl true
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

  def handle_info(%{event: "postgres_cdc_rls_down"}, socket) do
    pg_sub_ref = postgres_subscribe()

    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  def handle_info(%{event: "postgres_cdc_down"}, socket) do
    pg_sub_ref = postgres_subscribe()

    {:noreply, assign(socket, %{pg_sub_ref: pg_sub_ref})}
  end

  def handle_info(
        %{event: "presence_diff"},
        %{assigns: %{policies: %Policies{presence: %PresencePolicies{read: false}}}} = socket
      ) do
    Logger.warning("Presence message ignored")
    {:noreply, socket}
  end

  def handle_info(_msg, %{assigns: %{policies: %Policies{broadcast: %BroadcastPolicies{read: false}}}} = socket) do
    Logger.warning("Broadcast message ignored")
    {:noreply, socket}
  end

  def handle_info(%{event: type, payload: payload} = msg, socket) do
    socket = socket |> count() |> Logging.maybe_log_handle_info(msg)
    push(socket, type, payload)
    {:noreply, socket}
  end

  def handle_info(:postgres_subscribe, %{assigns: %{channel_name: channel_name}} = socket) do
    %{
      assigns: %{
        tenant: tenant,
        pg_sub_ref: pg_sub_ref,
        pg_change_params: pg_change_params,
        postgres_extension: postgres_extension,
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
            log_warning("UnableToSubscribeToPostgres", error)
            push_system_message("postgres_changes", socket, "error", error, channel_name)
            {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
        end

      nil ->
        Logger.warning("Re-connecting to PostgreSQL with params: " <> inspect(pg_change_params))
        {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe())}

      error ->
        log_warning("UnableToSubscribeToPostgres", error)
        push_system_message("postgres_changes", socket, "error", error, channel_name)
        {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
    end
  rescue
    error ->
      log_warning("UnableToSubscribeToPostgres", error)
      push_system_message("postgres_changes", socket, "error", error, channel_name)
      {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
  end

  def handle_info(:confirm_token, %{assigns: %{pg_change_params: pg_change_params}} = socket) do
    case confirm_token(socket) do
      {:ok, claims, confirm_token_ref, _, _} ->
        pg_change_params = Enum.map(pg_change_params, &Map.put(&1, :claims, claims))
        {:noreply, assign(socket, %{confirm_token_ref: confirm_token_ref, pg_change_params: pg_change_params})}

      {:error, :missing_claims} ->
        shutdown_response(socket, "Fields `role` and `exp` are required in JWT")

      {:error, :expired_token, msg} ->
        shutdown_response(socket, msg)

      {:error, error} ->
        shutdown_response(socket, to_log(error))
    end
  end

  def handle_info(:disconnect, %{assigns: %{channel_name: channel_name}} = socket) do
    Logger.info("Received operational call to disconnect channel")
    push_system_message("system", socket, "ok", "Server requested disconnect", channel_name)
    {:stop, :shutdown, socket}
  end

  def handle_info(:sync_presence, socket), do: PresenceHandler.sync(socket)

  def handle_info(msg, socket) do
    log_error("UnhandledSystemMessage", msg)
    {:noreply, socket}
  end

  @impl true
  def handle_in("broadcast", payload, socket), do: BroadcastHandler.handle(payload, socket)
  def handle_in("presence", payload, socket), do: PresenceHandler.handle(payload, socket)

  def handle_in(_, _, %{assigns: %{rate_counter: %{avg: avg}, limits: %{max_events_per_second: max}}} = socket)
      when avg > max do
    message = "Too many messages per second"

    shutdown_response(socket, message)
  end

  def handle_in("access_token", %{"access_token" => refresh_token}, %{assigns: %{access_token: access_token}} = socket)
      when refresh_token == access_token do
    {:noreply, socket}
  end

  def handle_in("access_token", %{"access_token" => refresh_token}, %{assigns: %{access_token: _access_token}} = socket)
      when is_nil(refresh_token) do
    {:noreply, socket}
  end

  def handle_in("access_token", %{"access_token" => refresh_token}, socket) when is_binary(refresh_token) do
    %{
      assigns: %{
        access_token: access_token,
        pg_sub_ref: pg_sub_ref,
        db_conn: db_conn,
        channel_name: channel_name,
        pg_change_params: pg_change_params
      }
    } = socket

    socket = assign(socket, :access_token, refresh_token)

    with {:ok, claims, confirm_token_ref, _, socket} <- confirm_token(socket),
         socket = assign_authorization_context(socket, channel_name, access_token, claims),
         {:ok, socket} <- maybe_assign_policies(channel_name, db_conn, socket) do
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
    else
      {:error, :unauthorized, msg} ->
        shutdown_response(socket, msg)

      {:error, :expired_token, msg} ->
        shutdown_response(socket, msg)

      {:error, :missing_claims} ->
        shutdown_response(socket, "Fields `role` and `exp` are required in JWT")

      {:error, :expected_claims_map} ->
        shutdown_response(socket, "Token claims must be a map")

      {:error, :unable_to_set_policies, _msg} ->
        shutdown_response(socket, "Realtime was unable to connect to the project database")

      {:error, error} ->
        shutdown_response(socket, inspect(error))
    end
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
    Logger.debug("Channel terminated with reason: #{reason}")
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

      error ->
        Logging.log_error_message(:error, "UnknownErrorOnCounter", error)
        {:error, error}
    end
  end

  def limit_channels(%{assigns: %{tenant: tenant, limits: limits}, transport_pid: pid}) do
    key = Tenants.channels_per_client_key(tenant)

    if Registry.count_match(Realtime.Registry, key, pid) + 1 > limits.max_channels_per_client do
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

  defp presence_key(params) do
    case params["config"]["presence"]["key"] do
      key when is_binary(key) and key != "" -> key
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

  defp confirm_token(%{assigns: assigns} = socket) do
    %{
      jwt_secret: jwt_secret,
      access_token: access_token
    } = assigns

    topic = Map.get(assigns, :topic)
    db_conn = Map.get(assigns, :db_conn)
    socket = Map.put(socket, :policies, nil)
    jwt_jwks = Map.get(assigns, :jwt_jwks)

    with jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec, jwt_jwks),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time(),
         {:ok, socket} <- maybe_assign_policies(topic, db_conn, socket) do
      if ref = assigns[:confirm_token_ref], do: Helpers.cancel_timer(ref)

      interval = min(@confirm_token_ms_interval, exp_diff * 1_000)
      ref = Process.send_after(self(), :confirm_token, interval)

      {:ok, claims, ref, access_token, socket}
    else
      {:error, error} -> {:error, error}
      {:error, error, message} -> {:error, error, message}
      e -> {:error, e}
    end
  end

  defp shutdown_response(socket, message) when is_binary(message) do
    %{assigns: %{channel_name: channel_name, access_token: access_token}} = socket
    metadata = log_metadata(access_token)
    push_system_message("system", socket, "error", message, channel_name)
    log_warning("ChannelShutdown", message, metadata)
    {:stop, :normal, socket}
  end

  defp push_system_message(extension, socket, status, error, channel_name)
       when is_map(error) and is_map_key(error, :error_code) and is_map_key(error, :error_message) do
    push(socket, "system", %{
      extension: extension,
      status: status,
      message: "#{error.error_code}: #{error.error_message}",
      channel: channel_name
    })
  end

  defp push_system_message(extension, socket, status, message, channel_name)
       when is_binary(message) do
    push(socket, "system", %{
      extension: extension,
      status: status,
      message: message,
      channel: channel_name
    })
  end

  defp push_system_message(extension, socket, status, message, channel_name) do
    push(socket, "system", %{
      extension: extension,
      status: status,
      message: inspect(message),
      channel: channel_name
    })
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

  defp new_api?(%{"config" => _}), do: true
  defp new_api?(_), do: false

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

  defp assign_authorization_context(socket, topic, access_token, claims) do
    authorization_context =
      Authorization.build_authorization_params(%{
        topic: topic,
        headers: Map.get(socket.assigns, :headers, []),
        jwt: access_token,
        claims: claims,
        role: claims["role"]
      })

    assign(socket, :authorization_context, authorization_context)
  end

  defp maybe_assign_policies(
         topic,
         db_conn,
         %{assigns: %{private?: true}} = socket
       )
       when not is_nil(topic) and not is_nil(db_conn) do
    %{using_broadcast?: using_broadcast?} = socket.assigns

    authorization_context = socket.assigns.authorization_context

    with {:ok, socket} <-
           Authorization.get_read_authorizations(socket, db_conn, authorization_context) do
      cond do
        match?(%Policies{broadcast: %BroadcastPolicies{read: false}}, socket.assigns.policies) ->
          {:error, :unauthorized, "You do not have permissions to read from this Channel topic: #{topic}"}

        using_broadcast? and
            match?(%Policies{broadcast: %BroadcastPolicies{read: false}}, socket.assigns.policies) ->
          {:error, :unauthorized, "You do not have permissions to read from this Channel topic: #{topic}"}

        true ->
          {:ok, socket}
      end
    else
      {:error, :increase_connection_pool} ->
        {:error, :increase_connection_pool}

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)

        {:error, :unauthorized, "You do not have permissions to read from this Channel topic: #{topic}"}

      {:error, error} ->
        {:error, :unable_to_set_policies, error}
    end
  end

  defp maybe_assign_policies(_, _, socket) do
    {:ok, assign(socket, policies: nil)}
  end

  defp only_private?(tenant_id, %{assigns: %{private?: private?}}) do
    tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)

    if tenant.private_only and !private?,
      do: {:error, :private_only},
      else: :ok
  end

  defp log_metadata(access_token) do
    access_token
    |> Joken.peek_claims()
    |> then(fn
      {:ok, claims} -> Map.get(claims, "sub")
      _ -> nil
    end)
    |> then(fn
      nil -> []
      sub -> [sub: sub]
    end)
  end
end
