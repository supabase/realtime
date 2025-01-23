defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  import Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.PostgresCdc
  alias Realtime.Tenants

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.RealtimeChannel
  ## Channels
  channel("realtime:*", RealtimeChannel)

  @default_log_level "error"

  @impl true
  def connect(params, socket, opts) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = opts

      {:ok, external_id} = Database.get_external_id(host)

      log_level =
        params
        |> Map.get("log_level", @default_log_level)
        |> then(fn
          "" -> @default_log_level
          level -> level
        end)
        |> String.to_existing_atom()

      Logger.metadata(external_id: external_id, project: external_id)
      Logger.put_process_level(self(), log_level)

      with %Tenant{
             extensions: extensions,
             jwt_secret: jwt_secret,
             jwt_jwks: jwt_jwks,
             max_concurrent_users: max_conn_users,
             max_events_per_second: max_events_per_second,
             max_bytes_per_second: max_bytes_per_second,
             max_joins_per_second: max_joins_per_second,
             max_channels_per_client: max_channels_per_client,
             postgres_cdc_default: postgres_cdc_default
           } <- Tenants.Cache.get_tenant_by_external_id(external_id),
           token when is_binary(token) <- access_token(params, headers),
           jwt_secret_dec <- Crypto.decrypt!(jwt_secret),
           {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec, jwt_jwks),
           {:ok, postgres_cdc_module} <- PostgresCdc.driver(postgres_cdc_default) do
        assigns = %RealtimeChannel.Assigns{
          claims: claims,
          jwt_secret: jwt_secret,
          jwt_jwks: jwt_jwks,
          limits: %{
            max_concurrent_users: max_conn_users,
            max_events_per_second: max_events_per_second,
            max_bytes_per_second: max_bytes_per_second,
            max_joins_per_second: max_joins_per_second,
            max_channels_per_client: max_channels_per_client
          },
          postgres_extension: PostgresCdc.filter_settings(postgres_cdc_default, extensions),
          postgres_cdc_module: postgres_cdc_module,
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
          {:error, :tenant_not_found}

        {:error, :expired_token, msg, claims} ->
          sub = Map.get(claims, "sub", nil)
          log_error("InvalidJWTToken", msg, sub: sub)
          {:error, :expired_token}

        {:error, :missing_claims} ->
          log_error("InvalidJWTToken", "Fields `role` and `exp` are required in JWT")
          {:error, :missing_claims}

        error ->
          log_error("ErrorConnectingToWebsocket", error)
          error
      end
    end
  end

  def access_token(params, headers) do
    case :proplists.lookup("x-api-key", headers) do
      :none -> Map.get(params, "apikey")
      {"x-api-key", token} -> token
    end
  end

  @impl true
  def id(%{assigns: %{tenant: tenant}}), do: subscribers_id(tenant)

  @spec subscribers_id(String.t()) :: String.t()
  def subscribers_id(tenant), do: "user_socket:" <> tenant
end
