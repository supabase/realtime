defmodule RealtimeWeb.ApiJwtSecretTest do
  use RealtimeWeb.ConnCase, async: false

  alias Realtime.ApiJwt.Validator

  @jwks_url "https://platform.example/.well-known/jwks.json"
  @issuer "https://platform.example"

  test "no api key", %{conn: conn} do
    previous = Application.get_env(:realtime, :api_jwt_secret)
    Application.put_env(:realtime, :api_jwt_secret, nil)
    on_exit(fn -> Application.put_env(:realtime, :api_jwt_secret, previous) end)

    conn = get(conn, Routes.tenant_path(conn, :index))
    assert conn.status == 403
  end

  test "api key is right", %{conn: conn} do
    api_jwt_secret = Application.get_env(:realtime, :api_jwt_secret)
    jwt = generate_jwt_token(api_jwt_secret)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
    conn = get(conn, Routes.tenant_path(conn, :index))
    assert conn.status == 200
  end

  describe "secret rotation" do
    setup do
      previous = Application.get_env(:realtime, :api_jwt_secret)
      Application.put_env(:realtime, :api_jwt_secret, ["current_secret", "next_secret"])
      on_exit(fn -> Application.put_env(:realtime, :api_jwt_secret, previous) end)
      :ok
    end

    test "api key signed with current secret", %{conn: conn} do
      jwt = generate_jwt_token("current_secret")
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 200
    end

    test "api key signed with next secret", %{conn: conn} do
      jwt = generate_jwt_token("next_secret")
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 200
    end

    test "api key signed with unknown secret", %{conn: conn} do
      jwt = generate_jwt_token("unknown_secret")
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 403
    end

    test "no secrets configured", %{conn: conn} do
      Application.put_env(:realtime, :api_jwt_secret, [])
      jwt = generate_jwt_token("current_secret")
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 403
    end
  end

  describe "web identity token" do
    setup do
      {signer, jwks} = generate_api_jwt_keys("api-jwt-kid")

      validator = %Validator{
        jwks_url: @jwks_url,
        issuer: @issuer,
        audiences: ["realtime"],
        subjects: ["platform-service"]
      }

      previous = Application.get_env(:realtime, :api_jwt_validators)
      Application.put_env(:realtime, :api_jwt_validators, [validator])
      Cachex.put(Realtime.ApiJwt.Jwks, @jwks_url, jwks)

      on_exit(fn ->
        Application.put_env(:realtime, :api_jwt_validators, previous)
        Cachex.clear(Realtime.ApiJwt.Jwks)
      end)

      %{signer: signer}
    end

    test "a valid web identity token is accepted", %{conn: conn, signer: signer} do
      jwt = generate_api_jwt_token(signer, %{})
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 200
    end

    test "an invalid web identity token is rejected", %{conn: conn, signer: signer} do
      jwt = generate_api_jwt_token(signer, %{"aud" => "wrong-audience"})
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 403
    end

    test "the legacy API_JWT_SECRET token still works alongside web identity", %{conn: conn} do
      api_jwt_secret = Application.get_env(:realtime, :api_jwt_secret)
      jwt = generate_jwt_token(api_jwt_secret)
      conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> jwt)
      conn = get(conn, Routes.tenant_path(conn, :index))
      assert conn.status == 200
    end
  end
end
