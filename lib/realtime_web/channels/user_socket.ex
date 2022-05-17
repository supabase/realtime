defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket
  require Logger
  alias Extensions.Postgres.Helpers
  alias RealtimeWeb.ChannelsAuthorization

  ## Channels
  channel "realtime:*", RealtimeWeb.RealtimeChannel

  @impl true
  def connect(params, socket, connect_info) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = connect_info
      [external_id | _] = String.split(host, ".", parts: 2)

      with tenant when tenant != nil <-
             Realtime.Api.get_tenant_by_external_id(:cached, external_id),
           token when token != nil <- access_token(params, headers),
           {:ok, claims} <- ChannelsAuthorization.authorize_conn(token, tenant.jwt_secret) do
        %{
          extensions: extensions,
          jwt_secret: jwt_secret,
          max_concurrent_users: max_concurrent_users
        } = tenant

        assigns = %{
          token: token,
          jwt_secret: jwt_secret,
          tenant: external_id,
          postgres_extension: Helpers.filter_postgres_settings(extensions),
          claims: claims,
          limits: %{
            max_concurrent_users: max_concurrent_users
          },
          params: %{
            ref: make_ref()
          }
        }

        {:ok, assign(socket, assigns)}
      else
        _ ->
          Logger.error("Auth error")
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
  def id(_socket), do: nil
end
