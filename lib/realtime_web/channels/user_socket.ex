defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  alias Realtime.{PostgresCdc, Api}
  alias Api.Tenant
  alias Realtime.Tenants
  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.RealtimeChannel
  import Realtime.Helpers, only: [decrypt!: 2, get_external_id: 1]

  ## Channels
  channel "realtime:*", RealtimeChannel

  @default_log_level "error"

  @impl true
  def connect(params, socket, connect_info) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = connect_info

      {:ok, external_id} = get_external_id(host)

      log_level =
        params
        |> Map.get("log_level", @default_log_level)
        |> case do
          "" -> @default_log_level
          level -> level
        end
        |> String.to_existing_atom()

      secure_key = Application.get_env(:realtime, :db_enc_key)

      Logger.metadata(external_id: external_id, project: external_id)
      Logger.put_process_level(self(), log_level)

      with %Tenant{
             extensions: extensions,
             jwt_secret: jwt_secret,
             max_concurrent_users: max_conn_users,
             max_events_per_second: max_events_per_second,
             max_bytes_per_second: max_bytes_per_second,
             max_joins_per_second: max_joins_per_second,
             max_channels_per_client: max_channels_per_client,
             postgres_cdc_default: postgres_cdc_default
           } <- Tenants.Cache.get_tenant_by_external_id(external_id),
           token when is_binary(token) <- access_token(params, headers),
           jwt_secret_dec <- decrypt!(jwt_secret, secure_key),
           {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec),
           {:ok, postgres_cdc_module} <- PostgresCdc.driver(postgres_cdc_default) do
        assigns =
          %RealtimeChannel.Assigns{
            claims: claims,
            jwt_secret: jwt_secret,
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
            tenant_token: token
          }
          |> Map.from_struct()

        {:ok, assign(socket, assigns)}
      else
        nil ->
          Logger.error("Auth error: tenant `#{external_id}` not found")
          :error

        error ->
          Logger.error("Auth error: #{inspect(error)}")
          :error
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
  def id(%{assigns: %{tenant: tenant}}) do
    subscribers_id(tenant)
  end

  @spec subscribers_id(String.t()) :: String.t()
  def subscribers_id(tenant) do
    "user_socket:" <> tenant
  end
end
