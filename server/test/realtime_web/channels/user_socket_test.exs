defmodule RealtimeWeb.UserSocketTest do
  use RealtimeWeb.ChannelCase

  import Mock

  alias Phoenix.Socket
  alias RealtimeWeb.{UserSocket, ChannelsAuthorization}

  test "connect/2 when :secure_channels config is false" do
    Application.put_env(:realtime, :secure_channels, false)

    assert {:ok, %Socket{}} = UserSocket.connect(%{}, socket(UserSocket), %{x_headers: []})
  end

  test "connect/2 when :secure_channels config is true and token is authorized" do
    with_mock ChannelsAuthorization,
      authorize: fn
        token when is_binary(token) -> {:ok, %{}}
        _ -> :error
      end do
      Application.put_env(:realtime, :secure_channels, true)

      # WARNING: "token" param key will be deprecated.
      assert {:ok, %Socket{assigns: %{access_token: "auth_token123"}}} =
               UserSocket.connect(%{"token" => "auth_token123"}, socket(UserSocket), %{
                 x_headers: []
               })

      # WARNING: "apikey" param key will be deprecated.
      assert {:ok, %Socket{assigns: %{access_token: "auth_token123"}}} =
               UserSocket.connect(%{"apikey" => "auth_token123"}, socket(UserSocket), %{
                 x_headers: []
               })

      assert {:ok, %Socket{assigns: %{access_token: "auth_token123"}}} =
               UserSocket.connect(%{}, socket(UserSocket), %{
                 x_headers: [{"x-api-key", "auth_token123"}]
               })
    end
  end

  test "connect/2 when :secure_channels config is true and token is unauthorized" do
    with_mock ChannelsAuthorization, authorize: fn _token -> {:error, "unauthorized"} end do
      Application.put_env(:realtime, :secure_channels, true)

      assert :error =
               UserSocket.connect(%{"token" => "bad_token9"}, socket(UserSocket), %{x_headers: []})

      assert :error =
               UserSocket.connect(%{}, socket(UserSocket), %{x_headers: [{"token", "bad_token9"}]})
    end
  end

  test "connect/2 when :secure_channels config is true and token is missing" do
    Application.put_env(:realtime, :secure_channels, true)

    assert :error = UserSocket.connect(%{}, socket(UserSocket), %{x_headers: []})
  end

  test "access_token/2 on different keys" do
    assert nil == UserSocket.access_token([], %{})

    assert "apikey" ==
             UserSocket.access_token([{"wrong_x-api-key", "x-api-key"}], %{
               "token" => "token",
               "apikey" => "apikey"
             })

    assert "token" ==
             UserSocket.access_token([{"wrong_x-api-key", "x-api-key"}], %{
               "token" => "token",
               "wrong_apikey" => "apikey"
             })

    assert "apikey" == UserSocket.access_token([], %{"token" => "token", "apikey" => "apikey"})
  end
end
