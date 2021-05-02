defmodule RealtimeWeb.UserSocket do
  use Phoenix.Socket

  alias RealtimeWeb.ChannelsAuthorization

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
  def connect(params, socket) do
    case Application.fetch_env!(:realtime, :secure_channels)
         |> authorize_conn(params) do
      :ok -> {:ok, socket}
      _ -> :error
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

  defp authorize_conn(true, %{"token" => token}) do
    # WARNING: "token" param key will be deprecated.
    # Please use "apikey" param key to pass in auth token.
    case ChannelsAuthorization.authorize(token) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp authorize_conn(true, %{"apikey" => token}) do
    case ChannelsAuthorization.authorize(token) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp authorize_conn(true, _params), do: :error
  defp authorize_conn(false, _params), do: :ok
end
