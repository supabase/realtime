defmodule RealtimeWeb.AuthTenantTest do
  use RealtimeWeb.ConnCase, async: true

  import Plug.Conn
  import ExUnit.CaptureLog

  alias RealtimeWeb.AuthTenant

  describe "without tenant" do
    test "returns 401", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "with tenant" do
    setup %{conn: conn} = context do
      tenant = tenant_fixture()
      now = System.system_time(:second)
      token = generate_jwt_token(tenant, %{role: "test", iat: now, exp: now + 100_000})

      header = Map.get(context, :header)

      api_key =
        cond do
          literal = Map.get(context, :api_key) -> literal
          header -> Map.get(context, :prefix, "Bearer ") <> token
          true -> nil
        end

      conn = if header && api_key, do: put_req_header(conn, header, api_key), else: conn

      conn = assign(conn, :tenant, tenant)
      %{conn: conn, token: token}
    end

    test "returns 401 if token isn't present in header", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag api_key: "Bearer invalid", header: "authorization"
    test "returns 401 if token in authorization header isn't valid", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag header: "authorization"
    test "returns non halted and null status if token in authorization header is valid", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag header: "authorization", prefix: "bearer "
    test "returns non halted and null status if token in authorization header is valid and case insensitive",
         %{
           conn: conn
         } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag api_key: "earer invalid", header: "authorization"
    test "returns halted and unauthorized if token is badly formatted", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag api_key: "invalid", header: "apikey"
    test "returns 401 if token in apikey header isn't valid", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag header: "apikey", prefix: ""
    test "returns non halted and null status if token in apikey header is valid", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag header: "authorization"
    test "assigns jwt information on success", %{conn: conn, token: token} do
      conn = AuthTenant.call(conn, %{})
      assert conn.assigns.jwt == token
      assert conn.assigns.role == "test"
      assert %{"exp" => exp, "iat" => iat, "role" => "test"} = conn.assigns.claims
      assert is_integer(exp) and is_integer(iat)
    end
  end

  describe "with JWKS that does not match the token kid" do
    # RS256 token with header kid "key-id-1"
    @rsa_token "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsImtpZCI6ImtleS1pZC0xIn0.eyJpYXQiOjE3MTIwNDc1NjUsInJvbGUiOiJhdXRoZW50aWNhdGVkIiwic3ViIjoidXNlci1pZCIsImV4cCI6MTcxMjA1MTE2NX0.zUeoZrWK1efAc4q9y978_9qkhdXktdjf5H8O9Rw0SHcPaXW8OBcuNR2huRrgORvqFx6_sHn6nCJaWkZGzO-f8wskMD7Z4INq2JUypr6nASie3Qu2lLyeY3WTInaXNAKH-oqlfTLRskbz8zkIxOj2bBJiN9ceQLkJU-c92ndiuiG5D1jyQrGsvRdFem_cemp0yOoEaC0XWdjeV6C_UD-34GIyv3o8H4HZg1GcCiyNnAfDmLAcTOQPmqkwsRDQb-pm5O3HwpQt9WHOB6i1vzf-nmIGyCRA7STPdALK16-aiAyT4SJRxM5WN3iK8yitH7g4JETb9WocBbwIM_zfNnUI5w"

    setup %{conn: conn} do
      jwks = %{"keys" => [%{"kty" => "RSA", "kid" => "some_other_kid"}]}
      tenant = tenant_fixture(%{jwt_jwks: jwks})
      %{conn: assign(conn, :tenant, tenant)}
    end

    test "logs JwtSignerError with the kid and returns 401", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer " <> @rsa_token)

      log =
        capture_log(fn ->
          conn = AuthTenant.call(conn, %{})
          assert conn.status == 401
          assert conn.halted
        end)

      assert log =~ "JwtSignerError"
      assert log =~ "key-id-1"
    end
  end
end
