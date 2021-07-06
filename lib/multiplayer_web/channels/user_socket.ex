defmodule MultiplayerWeb.UserSocket do
  use Phoenix.Socket
  require Logger
  alias MultiplayerWeb.ChannelsAuthorization

  ## Channels
  channel "room:*", MultiplayerWeb.RoomChannel
  channel "realtime:*", MultiplayerWeb.RealtimeChannel

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  def connect(params, socket, %{uri: %{host: host}}) do
    case Multiplayer.Api.get_project_by_host(host) do
      nil ->
        Logger.error("Undefined host " <> host)
        :error
      project ->
        token = Map.get(params, "apikey")
        case Application.fetch_env!(:multiplayer, :secure_channels)
            |> authorize_conn(token, project.jwt_secret) do
          :ok ->
            user_id = Map.get(params, "user_id", UUID.uuid4())
            assigns = %{scope: project.id, params: %{user_id: user_id}}
            {:ok, assign(socket, assigns)}
          _ -> :error
        end
    end
  end

  def connect(params, socket, _connect_info) do
    {_, params} = Map.pop(params, "vsn")
    params = for {key, val} <- params, into: %{}, do: {String.to_atom(key), val}
    {:ok, assign(socket, :params, params)}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     MultiplayerWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(_socket), do: nil

  defp authorize_conn(true, token, secret) do
    case ChannelsAuthorization.authorize(token, secret) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp authorize_conn(false, _, _), do: :ok
end
