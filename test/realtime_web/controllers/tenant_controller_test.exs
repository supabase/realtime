defmodule RealtimeWeb.TenantControllerTest do
  use RealtimeWeb.ConnCase

  import Mock
  import Realtime.Helpers, only: [encrypt!: 2]

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias RealtimeWeb.{ChannelsAuthorization, JwtVerification}

  @external_id "test_external_id"

  @create_attrs %{
    "name" => "localhost",
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "postgres",
          "db_password" => "postgres",
          "db_port" => "6432",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1"
        }
      }
    ],
    "postgres_cdc_default" => "postgres_cdc_rls",
    "jwt_secret" => "new secret"
  }

  @update_attrs %{
    jwt_secret: "some updated jwt_secret",
    name: "some updated name",
    max_concurrent_users: 200
  }

  @invalid_attrs %{external_id: nil, jwt_secret: nil, extensions: [], name: nil}

  def fixture(:tenant) do
    {:ok, tenant} =
      Map.put(@create_attrs, "external_id", @external_id)
      |> Api.create_tenant()

    tenant
  end

  setup %{conn: conn} do
    Application.put_env(:realtime, :db_enc_key, "1234567890123456")

    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    {:ok, conn: new_conn}
  end

  describe "create tenant" do
    test "renders tenant when data is valid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        ext_id = @external_id
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @create_attrs)
        assert %{"id" => _id, "external_id" => ^ext_id} = json_response(conn, 201)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))
        assert ^ext_id = json_response(conn, 200)["data"]["external_id"]
        assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
      end
    end

    test "encrypt creds", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        ext_id = @external_id
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @create_attrs)
        [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]
        sec_key = Application.get_env(:realtime, :db_enc_key)
        assert encrypt!("127.0.0.1", sec_key) == settings["db_host"]
        assert encrypt!("postgres", sec_key) == settings["db_name"]
        assert encrypt!("postgres", sec_key) == settings["db_user"]
        assert encrypt!("postgres", sec_key) == settings["db_password"]
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
      tenant: %Tenant{id: id, external_id: ext_id} = _tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @update_attrs)
        assert %{"id" => ^id, "external_id" => ^ext_id} = json_response(conn, 200)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))
        assert "some updated name" = json_response(conn, 200)["data"]["name"]
        assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
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

    test "tenant doesn't exist", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret -> {:ok, %{}} end do
        conn = delete(conn, Routes.tenant_path(conn, :delete, "wrong_external_id"))
        assert response(conn, 204)
      end
    end
  end

  describe "reload tenant" do
    test "reload when tenant does exist", %{conn: conn} do
      with_mocks [
        {ChannelsAuthorization, [], authorize: fn _, _ -> {:ok, %{}} end},
        {Api, [], get_tenant_by_external_id: fn _ -> %Tenant{} end}
      ] do
        Routes.tenant_path(conn, :reload, @external_id)
        %{status: status} = post(conn, Routes.tenant_path(conn, :reload, @external_id))
        assert status == 204
      end
    end

    test "reload when tenant does not exist", %{conn: conn} do
      with_mock ChannelsAuthorization, authorize: fn _, _ -> {:ok, %{}} end do
        Routes.tenant_path(conn, :reload, @external_id)
        %{status: status} = post(conn, Routes.tenant_path(conn, :reload, @external_id))
        assert status == 404
      end
    end
  end

  defp create_tenant(_) do
    tenant = fixture(:tenant)
    %{tenant: tenant}
  end
end
