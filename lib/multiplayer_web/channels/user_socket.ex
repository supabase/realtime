defmodule MultiplayerWeb.UserSocket do
  use Phoenix.Socket
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
  def connect(%{"scope" => scope} = params, socket, _connect_info) do
    case Application.fetch_env!(:multiplayer, :secure_channels)
         |> authorize_conn(params) do
      :ok ->
        user_id =
          case Map.get(params, "user_id", nil) do
            nil -> UUID.uuid4()
            user_id -> user_id
          end
        assigns = %{scope: scope, params: %{user_id: user_id}}
        {:ok, assign(socket, assigns)}
      _ -> :error
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

  defp authorize_conn(true, %{"apikey" => token, "scope" => _scope}) do
    secret = Application.fetch_env!(:multiplayer, :jwt_secret)
    case ChannelsAuthorization.authorize(token, secret) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp authorize_conn(true, _params), do: :error
  defp authorize_conn(false, _params), do: :ok
end
