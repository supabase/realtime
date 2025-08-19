defmodule RealtimeWeb.RealtimeChannel do
  @moduledoc """
  Used for handling channels and subscriptions.
  """
  use RealtimeWeb, :channel
  use Realtime.Logs

  alias RealtimeWeb.SocketDisconnect
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
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher
  alias RealtimeWeb.RealtimeChannel.PresenceHandler
  alias RealtimeWeb.RealtimeChannel.Tracker

  @confirm_token_ms_interval :timer.minutes(5)

  @impl true
  def join("realtime:", _params, socket) do
    Logging.log_error(socket, "TopicNameRequired", "You must provide a topic name")
  end

  def join("realtime:" <> sub_topic = topic, params, socket) do
    %{
      assigns: %{tenant: tenant_id, log_level: log_level, postgres_cdc_module: module},
      channel_pid: channel_pid,
      serializer: serializer,
      transport_pid: transport_pid
    } = socket

    Tracker.track(socket.transport_pid)
    Logger.metadata(external_id: tenant_id, project: tenant_id)
    Logger.put_process_level(self(), log_level)

    socket =
      socket
      |> assign_access_token(params)
      |> assign_counter()
      |> assign_presence_counter()
      |> assign(:private?, !!params["config"]["private"])
      |> assign(:policies, nil)

    with :ok <- SignalHandler.shutdown_in_progress?(),
         :ok <- only_private?(tenant_id, socket),
         :ok <- limit_joins(socket),
         :ok <- limit_channels(socket),
         :ok <- limit_max_users(socket),
         {:ok, claims, confirm_token_ref} <- confirm_token(socket),
         socket = assign_authorization_context(socket, sub_topic, claims),
         {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id),
         {:ok, socket} <- maybe_assign_policies(sub_topic, db_conn, socket) do
      tenant_topic = Tenants.tenant_topic(tenant_id, sub_topic, !socket.assigns.private?)

      # fastlane subscription
      metadata =
        MessageDispatcher.fastlane_metadata(transport_pid, serializer, topic, socket.assigns.log_level, tenant_id)

      RealtimeWeb.Endpoint.subscribe(tenant_topic, metadata: metadata)

      Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_id)

      is_new_api = new_api?(params)
      # TODO: Default will be moved to false in the future
      presence_enabled? =
        case get_in(params, ["config", "presence", "enabled"]) do
          enabled when is_boolean(enabled) -> enabled
          _ -> true
        end

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
        presence_enabled?: presence_enabled?
      }

      # Start presence and add user if presence is enabled
      if presence_enabled?, do: send(self(), :sync_presence)

      Realtime.UsersCounter.add(transport_pid, tenant_id)
      SocketDisconnect.add(tenant_id, socket)

      {:ok, state, assign(socket, assigns)}
    else
      {:error, :expired_token, msg} ->
        Logging.maybe_log_warning(socket, "InvalidJWTToken", msg)

      {:error, :missing_claims} ->
        msg = "Fields `role` and `exp` are required in JWT"
        Logging.maybe_log_warning(socket, "InvalidJWTToken", msg)

      {:error, :unauthorized, msg} ->
        Logging.log_error(socket, "Unauthorized", msg)

      {:error, :too_many_channels} ->
        msg = "Too many channels"
        Logging.log_error(socket, "ChannelRateLimitReached", msg)

      {:error, :too_many_connections} ->
        msg = "Too many connected users"
        Logging.log_error(socket, "ConnectionRateLimitReached", msg)

      {:error, :too_many_joins} ->
        msg = "ClientJoinRateLimitReached: Too many joins per second"
        {:error, %{reason: msg}}

      {:error, :increase_connection_pool} ->
        msg = "Please increase your connection pool size"
        Logging.log_error(socket, "IncreaseConnectionPool", msg)

      {:error, :tenant_db_too_many_connections} ->
        msg = "Database can't accept more connections, Realtime won't connect"
        Logging.log_error(socket, "DatabaseLackOfConnections", msg)

      {:error, :unable_to_set_policies, error} ->
        Logging.log_error(socket, "UnableToSetPolicies", error)
        {:error, %{reason: "Realtime was unable to connect to the project database"}}

      {:error, :tenant_database_unavailable} ->
        Logging.log_error(socket, "UnableToConnectToProject", "Realtime was unable to connect to the project database")

      {:error, :rpc_error, :timeout} ->
        Logging.log_error(socket, "TimeoutOnRpcCall", "Node request timeout")

      {:error, :rpc_error, reason} ->
        Logging.log_error(socket, "ErrorOnRpcCall", "RPC call error: " <> inspect(reason))

      {:error, :initializing} ->
        Logging.log_error(socket, "InitializingProjectConnection", "Realtime is initializing the project connection")

      {:error, :tenant_database_connection_initializing} ->
        Logging.log_error(socket, "InitializingProjectConnection", "Connecting to the project database")

      {:error, :token_malformed, msg} ->
        Logging.log_error(socket, "MalformedJWT", msg)

      {:error, invalid_exp} when is_integer(invalid_exp) and invalid_exp <= 0 ->
        Logging.log_error(socket, "InvalidJWTToken", "Token expiration time is invalid")

      {:error, :private_only} ->
        Logging.log_error(socket, "PrivateOnly", "This project only allows private channels")

      {:error, :tenant_not_found} ->
        Logging.log_error(socket, "TenantNotFound", "Tenant with the given ID does not exist")

      {:error, :tenant_suspended} ->
        Logging.log_error(socket, "RealtimeDisabledForTenant", "Realtime disabled for this tenant")

      {:error, :signature_error} ->
        Logging.log_error(socket, "JwtSignatureError", "Failed to validate JWT signature")

      {:error, :shutdown_in_progress} ->
        Logging.log_error(socket, "RealtimeRestarting", "Realtime is restarting, please standby")

      {:error, error} ->
        Logging.log_error(socket, "UnknownErrorOnChannel", error)
        {:error, %{reason: "Unknown Error on Channel"}}
    end
  end

  @impl true
  def handle_info(:update_rate_counter, %{assigns: %{limits: %{max_events_per_second: max}}} = socket) do
    count(socket)

    {:ok, rate_counter} = RateCounter.get(socket.assigns.rate_counter)

    if rate_counter.avg > max do
      message = "Too many messages per second"
      shutdown_response(socket, message)
    else
      {:noreply, socket}
    end
  end

  def handle_info(%{event: "postgres_cdc_rls_down"}, socket) do
    %{assigns: %{pg_sub_ref: pg_sub_ref}} = socket
    Helpers.cancel_timer(pg_sub_ref)
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

  def handle_info(%{event: "presence_diff", payload: payload} = msg, socket) do
    %{presence_rate_counter: presence_rate_counter, limits: %{max_events_per_second: max}} = socket.assigns

    GenCounter.add(presence_rate_counter.id)
    {:ok, rate_counter} = RateCounter.get(presence_rate_counter)

    # Let's just log for now
    if rate_counter.avg > max do
      message = "Too many presence messages per second"
      log_warning("TooManyPresenceMessages", message)
    end

    Logging.maybe_log_info(socket, msg)
    push(socket, "presence_diff", payload)
    {:noreply, socket}
  end

  def handle_info(%{event: type, payload: payload} = msg, socket) do
    count(socket)
    Logging.maybe_log_info(socket, msg)
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
            Logging.maybe_log_info(socket, message)
            push_system_message("postgres_changes", socket, "ok", message, channel_name)
            {:noreply, assign(socket, :pg_sub_ref, nil)}

          error ->
            Logging.maybe_log_warning(socket, "RealtimeDisabledForConfiguration", error)

            push_system_message("postgres_changes", socket, "error", error, channel_name)
            {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe(5, 10))}
        end

      nil ->
        Logging.maybe_log_warning(
          socket,
          "ReconnectSubscribeToPostgres",
          "Re-connecting to PostgreSQL with params: " <> inspect(pg_change_params)
        )

        {:noreply, assign(socket, :pg_sub_ref, postgres_subscribe())}

      error ->
        Logging.maybe_log_error(socket, "UnableToSubscribeToPostgres", error)
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
      {:ok, claims, confirm_token_ref} ->
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

  def handle_info(:sync_presence, %{assigns: %{presence_enabled?: true}} = socket), do: PresenceHandler.sync(socket)
  def handle_info(:sync_presence, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_in("broadcast", payload, %{assigns: %{private?: true}} = socket) do
    %{tenant: tenant_id} = socket.assigns

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id) do
      BroadcastHandler.handle(payload, db_conn, socket)
    else
      {:error, error} ->
        log_error("UnableToHandleBroadcast", error)
        {:noreply, socket}
    end
  end

  def handle_in("broadcast", payload, %{assigns: %{private?: false}} = socket) do
    BroadcastHandler.handle(payload, socket)
  end

  def handle_in("presence", payload, %{assigns: %{private?: true}} = socket) do
    %{tenant: tenant_id} = socket.assigns

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id) do
      PresenceHandler.handle(payload, db_conn, socket)
    else
      {:error, error} ->
        log_error("UnableToHandlePresence", error)
        {:noreply, socket}
    end
  end

  def handle_in("presence", payload, %{assigns: %{private?: false}} = socket) do
    PresenceHandler.handle(payload, socket)
  end

  def handle_in("access_token", %{"access_token" => "sb_" <> _}, socket) do
    {:noreply, socket}
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
        tenant: tenant_id,
        pg_sub_ref: pg_sub_ref,
        channel_name: channel_name,
        pg_change_params: pg_change_params
      }
    } = socket

    # Update token and reset policies
    socket = assign(socket, %{access_token: refresh_token, policies: nil})

    with {:ok, claims, confirm_token_ref} <- confirm_token(socket),
         socket = assign_authorization_context(socket, channel_name, claims),
         {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id),
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
      {:error, reason, msg} when reason in ~w(unauthorized expired_token token_malformed)a ->
        shutdown_response(socket, msg)

      {:error, :missing_claims} ->
        shutdown_response(socket, "Fields `role` and `exp` are required in JWT")

      {:error, :unable_to_set_policies, _msg} ->
        shutdown_response(socket, "Realtime was unable to connect to the project database")

      {:error, error} ->
        shutdown_response(socket, inspect(error))

      {:error, :rpc_error, :timeout} ->
        shutdown_response(socket, "Node request timeout")

      {:error, :rpc_error, reason} ->
        shutdown_response(socket, "RPC call error: " <> inspect(reason))
    end
  end

  def handle_in(type, payload, socket) do
    count(socket)

    # Log info here so that bad messages from clients won't flood Logflare
    # Can subscribe to a Channel with `log_level` `info` to see these messages
    message = "Unexpected message from client of type `#{type}` with payload: #{inspect(payload)}"
    Logger.info(message)

    {:noreply, socket}
  end

  @impl true
  def terminate(reason, %{transport_pid: transport_pid}) do
    Logger.debug("Channel terminated with reason: #{reason}")
    :telemetry.execute([:prom_ex, :plugin, :realtime, :disconnected], %{})
    Tracker.untrack(transport_pid)
    :ok
  end

  defp postgres_subscribe(min \\ 1, max \\ 3) do
    Process.send_after(self(), :postgres_subscribe, backoff(min, max))
  end

  defp backoff(min, max) do
    {wait, _} = Backoff.backoff(%Backoff{type: :rand, min: min * 1000, max: max * 1000})
    wait
  end

  def limit_joins(%{assigns: %{tenant: tenant, limits: limits}} = socket) do
    rate_args = Tenants.joins_per_second_rate(tenant, limits.max_joins_per_second)

    RateCounter.new(rate_args)

    case RateCounter.get(rate_args) do
      {:ok, %{avg: avg}} when avg < limits.max_joins_per_second ->
        GenCounter.add(rate_args.id)
        :ok

      {:ok, %{avg: _}} ->
        {:error, :too_many_joins}

      error ->
        Logging.log_error(socket, "UnknownErrorOnCounter", error)
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

  defp limit_max_users(%{assigns: %{limits: %{max_concurrent_users: max_conn_users}, tenant: tenant}}) do
    conns = Realtime.UsersCounter.tenant_users(tenant)

    if conns < max_conn_users,
      do: :ok,
      else: {:error, :too_many_connections}
  end

  defp assign_counter(%{assigns: %{tenant: tenant, limits: limits}} = socket) do
    rate_args = Tenants.events_per_second_rate(tenant, limits.max_events_per_second)

    RateCounter.new(rate_args)
    assign(socket, :rate_counter, rate_args)
  end

  defp assign_counter(socket), do: socket

  defp assign_presence_counter(%{assigns: %{tenant: tenant, limits: limits}} = socket) do
    rate_args = Tenants.presence_events_per_second_rate(tenant, limits.max_events_per_second)

    RateCounter.new(rate_args)

    assign(socket, :presence_rate_counter, rate_args)
  end

  defp count(%{assigns: %{rate_counter: counter}}), do: GenCounter.add(counter.id)

  defp presence_key(params) do
    case params["config"]["presence"]["key"] do
      key when is_binary(key) and key != "" -> key
      _ -> UUID.uuid1()
    end
  end

  defp assign_access_token(%{assigns: %{headers: headers}} = socket, params) do
    access_token = Map.get(params, "access_token") || Map.get(params, "user_token")
    {_, header} = Enum.find(headers, {nil, nil}, fn {k, _} -> k == "x-api-key" end)

    case access_token do
      nil -> assign(socket, :access_token, header)
      "sb_" <> _ -> assign(socket, :access_token, header)
      _ -> handle_access_token(socket, params)
    end
  end

  defp assign_access_token(socket, params), do: handle_access_token(socket, params)

  defp handle_access_token(%{assigns: %{tenant_token: _tenant_token}} = socket, %{"user_token" => user_token})
       when is_binary(user_token) do
    assign(socket, :access_token, user_token)
  end

  defp handle_access_token(%{assigns: %{tenant_token: _tenant_token}} = socket, %{"access_token" => access_token})
       when is_binary(access_token) do
    assign(socket, :access_token, access_token)
  end

  defp handle_access_token(%{assigns: %{tenant_token: tenant_token}} = socket, _params) when is_binary(tenant_token) do
    assign(socket, :access_token, tenant_token)
  end

  defp confirm_token(%{assigns: assigns} = socket) do
    %{jwt_secret: jwt_secret, access_token: access_token} = assigns

    jwt_jwks = Map.get(assigns, :jwt_jwks)

    with jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
         {:ok, %{"exp" => exp} = claims} when is_integer(exp) <-
           ChannelsAuthorization.authorize_conn(access_token, jwt_secret_dec, jwt_jwks),
         exp_diff when exp_diff > 0 <- exp - Joken.current_time() do
      if ref = assigns[:confirm_token_ref], do: Helpers.cancel_timer(ref)

      interval = min(@confirm_token_ms_interval, exp_diff * 1000)
      ref = Process.send_after(self(), :confirm_token, interval)

      {:ok, claims, ref}
    else
      {:error, :token_malformed} ->
        {:error, :token_malformed, "The token provided is not a valid JWT"}

      {:error, error} ->
        {:error, error}

      {:error, error, message} ->
        {:error, error, message}

      e ->
        {:error, e}
    end
  end

  defp shutdown_response(socket, message) when is_binary(message) do
    %{assigns: %{channel_name: channel_name}} = socket
    push_system_message("system", socket, "error", message, channel_name)
    Logging.maybe_log_warning(socket, "ChannelShutdown", message)
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

  defp new_api?(%{"config" => _}), do: true
  defp new_api?(_), do: false

  defp pg_change_params(true, params, channel_pid, claims, _) do
    case get_in(params, ["config", "postgres_changes"]) do
      [_ | _] = params_list ->
        params_list
        |> Enum.reject(&is_nil/1)
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

  defp assign_authorization_context(socket, topic, claims) do
    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: socket.assigns.tenant,
        topic: topic,
        headers: Map.get(socket.assigns, :headers, []),
        claims: claims,
        role: claims["role"]
      })

    assign(socket, :authorization_context, authorization_context)
  end

  defp maybe_assign_policies(topic, db_conn, %{assigns: %{private?: true}} = socket)
       when not is_nil(topic) do
    authorization_context = socket.assigns.authorization_context
    policies = socket.assigns.policies || %Policies{}

    with {:ok, policies} <- Authorization.get_read_authorizations(policies, db_conn, authorization_context) do
      socket = assign(socket, :policies, policies)

      if match?(%Policies{broadcast: %BroadcastPolicies{read: false}}, socket.assigns.policies),
        do: {:error, :unauthorized, "You do not have permissions to read from this Channel topic: #{topic}"},
        else: {:ok, socket}
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

  defp maybe_assign_policies(_, _, socket), do: {:ok, assign(socket, policies: nil)}

  defp only_private?(tenant_id, %{assigns: %{private?: private?}}) do
    tenant = Tenants.Cache.get_tenant_by_external_id(tenant_id)

    if tenant.private_only and !private?,
      do: {:error, :private_only},
      else: :ok
  end
end
