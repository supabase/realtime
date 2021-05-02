defmodule RealtimeWeb.ChannelsAuthorizationTest do
  use ExUnit.Case

  import Mock

  alias RealtimeWeb.{ChannelsAuthorization, JwtVerification}

  test "authorize/1 when token is authorized" do
    input_token = "\n token %20 1 %20 2 %20 3   "
    expected_token = "token123"

    with_mock JwtVerification,
      verify: fn token ->
        assert token == expected_token
        {:ok, %{}}
      end do
      assert {:ok, %{}} = ChannelsAuthorization.authorize(input_token)
    end
  end

  test "authorize/1 when token is unauthorized" do
    with_mock JwtVerification, verify: fn _token -> {:error, "unauthorized"} end do
      assert {:error, "unauthorized"} = ChannelsAuthorization.authorize("bad_token9")
    end
  end

  test "authorize/1 when token is not a string" do
    assert :error = ChannelsAuthorization.authorize([])
  end
end
