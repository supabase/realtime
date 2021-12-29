defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket

  alias RealtimeWeb.ChannelsAuthorization

  defoverridable init: 1

  def init(state) do
    res = {:ok, {_, socket}} = super(state)
    Realtime.Metrics.SocketMonitor.track_socket(socket)
    res
  end

  ## Channels
  channel "realtime:*", RealtimeWeb.RealtimeChannel

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
  def connect(params, socket, %{x_headers: headers}) do
    if Application.fetch_env!(:realtime, :secure_channels) do
      token = access_token(headers, params)

      case ChannelsAuthorization.authorize(token) do
        {:ok, _} -> {:ok, assign(socket, :access_token, token)}
        _ -> :error
      end
    else
      {:ok, socket}
    end
  end

  @spec access_token([{String.t(), String.t()}], map) :: String.t() | nil
  def access_token(headers, params) do
    case :proplists.get_value("x-api-key", headers, nil) do
      nil ->
        # WARNING: "token" and "apikey" param keys will be deprecated.
        # Please use "x-api-key" header param key to pass in auth token.
        case params do
          %{"apikey" => token} -> token
          %{"token" => token} -> token
          _ -> nil
        end

      token ->
        token
    end
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     RealtimeWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  def id(_socket), do: nil
end
