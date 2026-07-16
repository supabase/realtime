defmodule Realtime.ApiJwt.JwksTest do
  use ExUnit.Case, async: false

  alias Realtime.ApiJwt.Jwks

  @jwks %{"keys" => [%{"kty" => "RSA", "kid" => "k1", "n" => "abc", "e" => "AQAB"}]}

  setup do
    Cachex.clear(Jwks)
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:realtime, :api_jwt_jwks_req_options)
    Application.put_env(:realtime, :api_jwt_jwks_req_options, plug: {Req.Test, Jwks})

    on_exit(fn ->
      if previous do
        Application.put_env(:realtime, :api_jwt_jwks_req_options, previous)
      else
        Application.delete_env(:realtime, :api_jwt_jwks_req_options)
      end

      Cachex.clear(Jwks)
    end)

    :ok
  end

  test "fetches and caches the JWKS (single HTTP call on hit)" do
    url = "https://example.test/jwks-1"
    parent = self()
    Req.Test.stub(Jwks, fn conn -> send(parent, :called) && Req.Test.json(conn, @jwks) end)

    assert {:ok, @jwks} == Jwks.fetch(url)
    assert {:ok, @jwks} == Jwks.fetch(url)

    assert_received :called
    refute_received :called
  end

  test "refresh re-fetches once, then serves from the cooldown window" do
    url = "https://example.test/jwks-2"
    parent = self()
    Req.Test.stub(Jwks, fn conn -> send(parent, :called) && Req.Test.json(conn, @jwks) end)

    assert {:ok, @jwks} == Jwks.fetch(url)
    assert_received :called
    # first refresh re-fetches (unknown kid path)
    assert {:ok, @jwks} == Jwks.refresh(url)
    assert_received :called
    # a storm of unknown kids within the cooldown must NOT re-fetch again
    assert {:ok, @jwks} == Jwks.refresh(url)
    assert {:ok, @jwks} == Jwks.refresh(url)
    refute_received :called
  end

  test "a failed refresh leaves the previously cached JWKS intact" do
    url = "https://example.test/jwks-2b"
    Req.Test.stub(Jwks, fn conn -> Req.Test.json(conn, @jwks) end)
    assert {:ok, @jwks} == Jwks.fetch(url)

    # JWKS endpoint starts failing; a refresh triggered by an unknown kid errors
    Req.Test.stub(Jwks, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
    assert {:error, {:http_error, 500}} == Jwks.refresh(url)

    # the good keys are still cached for legitimate tokens
    assert {:ok, @jwks} == Jwks.fetch(url)
  end

  test "returns error on non-2xx status and does not cache" do
    url = "https://example.test/jwks-3"
    parent = self()

    Req.Test.stub(Jwks, fn conn ->
      send(parent, :called)
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:http_error, 500}} == Jwks.fetch(url)
    # not cached: fetching again hits the stub a second time
    assert {:error, {:http_error, 500}} == Jwks.fetch(url)
    assert_received :called
    assert_received :called
  end

  test "returns error on a body without keys" do
    url = "https://example.test/jwks-4"
    Req.Test.stub(Jwks, fn conn -> Req.Test.json(conn, %{"nope" => true}) end)

    assert {:error, :invalid_jwks} == Jwks.fetch(url)
  end
end
