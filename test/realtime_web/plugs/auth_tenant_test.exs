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

      conn =
        if api_key, do: put_req_header(conn, "authorization", "Bearer #{api_key}"), else: conn

      conn = assign(conn, :tenant, tenant_fixture())
      %{conn: conn}
    end

    test "returns 401 if token isn't present in header", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag api_key: "invalid"
    test "returns 401 if token in header isn't valid", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      assert conn.status == 401
      assert conn.halted
    end

    @tag api_key: @token
    test "returns non halted and null status if token in header is valid", %{conn: conn} do
      conn = AuthTenant.call(conn, %{})
      refute conn.status
      refute conn.halted
    end
  end
end
