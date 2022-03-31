defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket
  require Logger
  alias RealtimeWeb.ChannelsAuthorization

  ## Channels
  channel "room:*", RealtimeWeb.RoomChannel
  channel "realtime:*", RealtimeWeb.RealtimeChannel

  @impl true
  def connect(params, socket, connect_info) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = connect_info
      [external_id | _] = String.split(host, ".", parts: 2)

      with tenant when tenant != nil <- Realtime.Api.get_tenant_by_external_id(external_id),
           token when token != nil <- access_token(params, headers),
           {:ok, claims} <- authorize_conn(token, tenant.jwt_secret) do
        assigns = %{
          tenant: external_id,
          claims: claims,
          limits: %{max_concurrent_users: tenant.max_concurrent_users},
          params: %{
            ref: make_ref()
          }
        }

        params = filter_postgres_settings(tenant.extensions)
        Extensions.Postgres.start_distributed(external_id, params)

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

  defp authorize_conn(token, secret) do
    case ChannelsAuthorization.authorize(token, secret) do
      # TODO: check necessary fields
      {:ok, %{"role" => _} = claims} ->
        {:ok, claims}

      _ ->
        :error
    end
  end

  defp filter_postgres_settings(extensions) do
    [postgres] =
      Enum.filter(extensions, fn e ->
        if e.type == "postgres" do
          true
        else
          false
        end
      end)

    postgres.settings
  end
end
