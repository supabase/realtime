defmodule RealtimeWeb.AuthTenantTest do
  use RealtimeWeb.ConnCase

  import Plug.Conn

  alias RealtimeWeb.AuthTenant

  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE1MTYyMzkwMjIsInJvbGUiOiJmb28iLCJleHAiOiJiYXIifQ.Ret2CevUozCsPhpgW2FMeFL7RooLgoOvfQzNpLBj5ak"
  describe "without tenant" do
    test "returns 401", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "with tenant" do
    setup %{conn: conn} = context do
      start_supervised!(RealtimeWeb.Joken.CurrentTime.Mock)
      api_key = Map.get(context, :api_key)
      header = Map.get(context, :header)

      conn = if api_key, do: put_req_header(conn, header, api_key), else: conn

      conn = assign(conn, :tenant, tenant_fixture())
      %{conn: conn}
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

    @tag api_key: "Bearer #{@token}", header: "authorization"
    test "returns non halted and null status if token in authorization header is valid", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag api_key: "bearer #{@token}", header: "authorization"
    test "returns non halted and null status if token in authorization header is valid and case insensitive",
         %{
           conn: conn
         } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag api_key: "earer #{@token}", header: "authorization"
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

    @tag api_key: @token, header: "apikey"
    test "returns non halted and null status if token in apikey header is valid", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end

    @tag api_key: "Bearer #{@token}", header: "authorization"
    test "assigns jwt information on success", %{
      conn: conn
    } do
      conn = AuthTenant.call(conn, %{})
      assert conn.assigns.jwt == @token
      assert conn.assigns.claims == %{"exp" => "bar", "iat" => 1_516_239_022, "role" => "foo"}
      assert conn.assigns.role == "foo"
    end
  end
end
