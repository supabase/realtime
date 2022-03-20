defmodule MultiplayerWeb.TenantControllerTest do
  use MultiplayerWeb.ConnCase

  import Mock

  alias Multiplayer.Api
  alias Multiplayer.Api.Tenant
  alias MultiplayerWeb.{ChannelsAuthorization, JwtVerification}

  @create_attrs %{
    external_id: "some external_id",
    active: true,
    name: "some name",
    db_host: "db.awesome.supabase.net",
    db_name: "postgres",
    db_password: "postgres",
    db_port: "6543",
    region: "eu-central-1",
    db_user: "postgres",
    jwt_secret: "some jwt_secret",
    rls_poll_interval: 500
  }
  @update_attrs %{
    jwt_secret: "some updated jwt_secret",
    name: "some updated name"
  }
  @invalid_attrs %{external_id: nil, jwt_secret: nil, name: nil}

  def fixture(:tenant) do
    {:ok, tenant} = Api.create_tenant(@create_attrs)
    tenant
  end

  setup %{conn: conn} do
    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    {:ok, conn: new_conn}
  end

  describe "index" do
    test "lists all tenants", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = get(conn, Routes.tenant_path(conn, :index))
        assert json_response(conn, 200)["data"] == []
      end
    end
  end

  describe "create tenant" do
    test "renders tenant when data is valid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = post(conn, Routes.tenant_path(conn, :create), tenant: @create_attrs)
        assert %{"id" => id, "external_id" => ext_id} = json_response(conn, 201)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))

        assert %{
                 "id" => id,
                 "active" => true,
                 "db_host" => "db.awesome.supabase.net",
                 "db_name" => "postgres",
                 "db_password" => "postgres",
                 "db_port" => "6543",
                 "db_user" => "postgres",
                 "external_id" => "some external_id",
                 "jwt_secret" => "some jwt_secret",
                 "name" => "some name",
                 "region" => "eu-central-1",
                 "rls_poll_interval" => 500
               } = json_response(conn, 200)["data"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = post(conn, Routes.tenant_path(conn, :create), tenant: @invalid_attrs)
        assert json_response(conn, 422)["errors"] != %{}
      end
    end
  end

  describe "update tenant" do
    setup [:create_tenant]

    test "renders tenant when data is valid", %{
      conn: conn,
      tenant: %Tenant{id: id, external_id: ext_id} = tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @update_attrs)
        assert %{"id" => ^id, "external_id" => ^ext_id} = json_response(conn, 200)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))

        assert %{
                 "id" => id,
                 "active" => true,
                 "db_host" => "db.awesome.supabase.net",
                 "db_name" => "postgres",
                 "db_password" => "postgres",
                 "db_port" => "6543",
                 "db_user" => "postgres",
                 "external_id" => "some external_id",
                 "jwt_secret" => "some updated jwt_secret",
                 "name" => "some updated name",
                 "region" => "eu-central-1",
                 "rls_poll_interval" => 500
               } = json_response(conn, 200)["data"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn =
          put(conn, Routes.tenant_path(conn, :update, tenant.external_id), tenant: @invalid_attrs)

        assert json_response(conn, 422)["errors"] != %{}
      end
    end
  end

  describe "delete tenant" do
    setup [:create_tenant]

    test "deletes chosen tenant", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = delete(conn, Routes.tenant_path(conn, :delete, tenant.external_id))
        assert response(conn, 204)
        conn = get(conn, Routes.tenant_path(conn, :show, tenant.external_id))
        assert response(conn, 404)
      end
    end
  end

  defp create_tenant(_) do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end
end
