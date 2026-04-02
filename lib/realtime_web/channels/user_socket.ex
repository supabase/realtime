defmodule RealtimeWeb.UserSocket do
  use RealtimeWeb.Socket
  use Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.Tenants

  alias RealtimeWeb.TenantRateLimiters
  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.RealtimeChannel.Logging

  ## Channels
  channel "realtime:*", RealtimeChannel

  @default_log_level :error

  @impl true
  def id(%{assigns: %{tenant: tenant}}), do: subscribers_id(tenant)

  @spec subscribers_id(String.t()) :: String.t()
  def subscribers_id(tenant), do: "user_socket:" <> tenant

  @impl true
  def connect(params, socket, opts) do
    %{uri: %{host: host}, x_headers: headers} = opts

    {:ok, external_id} = Database.get_external_id(host)
    token = access_token(params, headers)
    log_level = log_level(params)

    Logger.metadata(external_id: external_id, project: external_id)
    Logger.put_process_level(self(), log_level)

    socket =
      socket
      |> assign(:tenant, external_id)
      |> assign(:log_level, log_level)
      |> assign(:access_token, token)

    with %Tenant{
           jwt_secret: jwt_secret,
           jwt_jwks: jwt_jwks,
           suspend: false
         } = tenant <- Tenants.Cache.get_tenant_by_external_id(external_id),
         token when is_binary(token) <- token,
         jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
         {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec, jwt_jwks),
         :ok <- TenantRateLimiters.check_tenant(tenant) do
      assigns = %RealtimeChannel.Assigns{
        claims: claims,
        jwt_secret: jwt_secret,
        jwt_jwks: jwt_jwks,
        tenant: external_id,
        log_level: log_level,
        tenant_token: token,
        headers: opts.x_headers
      }

      assigns = Map.from_struct(assigns)

      {:ok, assign(socket, assigns)}
    else
      nil ->
        log_error("TenantNotFound", "Tenant not found: #{external_id}")
        connect_error(:tenant_not_found)

      %Tenant{suspend: true} ->
        Logging.log_error(socket, "RealtimeDisabledForTenant", "Realtime disabled for this tenant")
        connect_error(:tenant_suspended)

      {:error, :expired_token, msg} ->
        Logging.maybe_log_warning(socket, "InvalidJWTToken", msg)
        connect_error(:expired_token)

      {:error, :missing_claims} ->
        msg = "Fields `role` and `exp` are required in JWT"
        Logging.maybe_log_warning(socket, "InvalidJWTToken", msg)
        connect_error(:missing_claims)

      {:error, :token_malformed} ->
        log_error("MalformedJWT", "The token provided is not a valid JWT")
        connect_error(:token_malformed)

      {:error, :too_many_connections} ->
        msg = "Too many connected users"
        Logging.log_error(socket, "ConnectionRateLimitReached", msg)
        connect_error(:too_many_connections)

      {:error, :too_many_joins} ->
        msg = "Too many joins per second"
        Logging.log_error(socket, "JoinsRateLimitReached", msg)
        connect_error(:too_many_joins)

      error ->
        log_error("ErrorConnectingToWebsocket", error)
        connect_error(error)
    end
  end

  defp access_token(params, headers) do
    case :proplists.lookup("x-api-key", headers) do
      :none -> Map.get(params, "apikey")
      {"x-api-key", token} -> token
    end
  end

  defp log_level(params) do
    case Map.get(params, "log_level") do
      level when level in ["info", "warning", "error"] -> String.to_existing_atom(level)
      _ -> @default_log_level
    end
  end

  defp connect_error(reason) do
    Process.sleep(connect_error_backoff_ms())
    {:error, reason}
  end

  defp connect_error_backoff_ms(), do: :persistent_term.get({__MODULE__, :connect_error_backoff_ms})
end
