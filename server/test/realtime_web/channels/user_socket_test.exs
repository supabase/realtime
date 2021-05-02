defmodule RealtimeWeb.UserSocketTest do
  use RealtimeWeb.ChannelCase

  import Mock

  alias Phoenix.Socket
  alias RealtimeWeb.{UserSocket, ChannelsAuthorization}

  test "connect/2 when :secure_channels config is false" do
    Application.put_env(:realtime, :secure_channels, false)

    assert {:ok, %Socket{}} = UserSocket.connect(%{}, socket(UserSocket))
  end

  test "connect/2 when :secure_channels config is true and token is authorized" do
    with_mock ChannelsAuthorization, authorize: fn _token -> {:ok, %{}} end do
      Application.put_env(:realtime, :secure_channels, true)

      # WARNING: "token" param key will be deprecated.
      assert {:ok, %Socket{}} =
               UserSocket.connect(%{"token" => "auth_token123"}, socket(UserSocket))

      assert {:ok, %Socket{}} =
               UserSocket.connect(%{"apikey" => "auth_token123"}, socket(UserSocket))
    end
  end

  test "connect/2 when :secure_channels config is true and token is unauthorized" do
    with_mock ChannelsAuthorization, authorize: fn _token -> {:error, "unauthorized"} end do
      Application.put_env(:realtime, :secure_channels, true)

      assert :error = UserSocket.connect(%{"token" => "bad_token9"}, socket(UserSocket))
    end
  end

  test "connect/2 when :secure_channels config is true and token is missing" do
    Application.put_env(:realtime, :secure_channels, true)

    assert :error = UserSocket.connect(%{}, socket(UserSocket))
  end
end
