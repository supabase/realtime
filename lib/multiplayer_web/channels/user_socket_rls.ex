defmodule MultiplayerWeb.UserSocketRls do
  use Phoenix.Socket
  require Logger
  alias MultiplayerWeb.ChannelsAuthorization

  ## Channels
  channel "room:*", MultiplayerWeb.RoomChannel
  channel "realtime:*", MultiplayerWeb.RealtimeChannel

  @landing_host "multiplayer.red"

  @impl true
  def connect(params, socket, %{uri: %{host: @landing_host}}) do
    {_, params} = Map.pop(params, "vsn")
    params = for {key, val} <- params, into: %{}, do: {String.to_atom(key), val}
    {:ok, assign(socket, :params, params)}
  end

  def connect(params, socket, connect_info) do
    if Application.fetch_env!(:multiplayer, :secure_channels) do
      %{uri: %{host: host}, x_headers: headers} = connect_info
      #  , hooks = Multiplayer.Api.get_hooks_by_project_id(project.id)
      with project when project != nil <- Multiplayer.Api.get_project_by_host(host),
           token when token != nil <- access_token(params, headers),
           {:ok, claims} <- authorize_conn(token, project.jwt_secret) do
        assigns = %{
          scope: project.id,
          claims: claims,
          params: %{
            # hooks: hooks,
            ref: make_ref()
          }
        }

        # TODO: check if connection exist
        Ewalrus.start(
          project.id,
          project.db_host,
          project.db_name,
          project.db_user,
          project.db_password
        )

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
      token -> token
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
end
