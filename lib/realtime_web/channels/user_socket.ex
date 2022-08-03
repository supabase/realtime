defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket

  require Logger

  alias Realtime.Api.Tenant
  alias Extensions.Postgres.Helpers
  alias RealtimeWeb.ChannelsAuthorization
  import Realtime.Helpers, only: [decrypt!: 2]

  ## Channels
  channel "realtime:*", RealtimeWeb.RealtimeChannel

  @impl true
  def connect(params, socket, connect_info) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = connect_info
      [external_id | _] = String.split(host, ".", parts: 2)

      secure_key = Application.get_env(:realtime, :db_enc_key)

      with %Tenant{
             extensions: extensions,
             jwt_secret: jwt_secret,
             max_concurrent_users: max_conn_users
           } <- Realtime.Api.get_tenant_by_external_id(external_id),
           token when is_binary(token) <- access_token(params, headers),
           jwt_secret_dec <- decrypt!(jwt_secret, secure_key),
           {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, jwt_secret_dec) do
        assigns = %{
          claims: claims,
          is_new_api: !!params["vsndate"],
          jwt_secret: jwt_secret,
          limits: %{max_concurrent_users: max_conn_users},
          postgres_extension: Helpers.filter_postgres_settings(extensions),
          tenant: external_id,
          token: token
        }

        Logger.metadata(external_id: external_id, project: external_id)

        {:ok, assign(socket, assigns)}
      else
        error ->
          Logger.error("Auth error: #{inspect(error)}")
          :error
      end
    end
  end

  def access_token(params, headers) do
    case :proplists.lookup("x-api-key", headers) do
      :none -> Map.get(params, "apikey", "")
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
