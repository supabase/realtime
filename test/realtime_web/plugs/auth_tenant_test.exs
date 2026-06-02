defmodule RealtimeWeb.AuthTenantTest do
  use RealtimeWeb.ConnCase, async: true

  import Plug.Conn

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
end
