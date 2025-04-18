defmodule RealtimeWeb.TenantControllerTest do
  # async: false due to the usage of mocks
  use RealtimeWeb.ConnCase, async: false

  import Mock

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.PromEx.Plugins.Tenants
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter
  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.JwtVerification

  @update_attrs %{
    jwt_secret: "some updated jwt_secret",
    name: "some updated name",
    max_concurrent_users: 300,
    max_channels_per_client: 150,
    max_events_per_second: 250,
    max_joins_per_second: 50
  }

  @default_tenant_attrs %{
    "external_id" => "external_id",
    "name" => "external_id",
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
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

  @invalid_attrs %{external_id: nil, jwt_secret: nil, extensions: [], name: nil}

  setup %{conn: conn} do
    Application.put_env(:realtime, :db_enc_key, "1234567890123456")

    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    on_exit(fn -> Realtime.Tenants.Connect.shutdown("dev_tenant") end)

    {:ok, conn: new_conn}
  end

  describe "show tenant" do
    test "removes db_password", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = get(conn, Routes.tenant_path(conn, :show, "dev_tenant"))
        response = json_response(conn, 200)

        refute get_in(response, ["data", "extensions", Access.at(0), "settings", "db_password"])
      end
    end

    test "returns not found on non existing tenant", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = get(conn, Routes.tenant_path(conn, :show, "nope"))
        response = json_response(conn, 404)
        assert response == %{"error" => "not found"}
      end
    end
  end

  describe "create tenant" do
    test "renders tenant when data is valid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        external_id = random_string()
        port = Enum.random(5000..9000)
        attrs = default_tenant_attrs(port)

        Containers.initialize_no_tenant(external_id, port)
        on_exit(fn -> Containers.stop_container(external_id) end)

        conn = put(conn, Routes.tenant_path(conn, :update, external_id), tenant: attrs)
        assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, external_id))
        assert ^external_id = json_response(conn, 200)["data"]["external_id"]
        assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
        assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
        assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
        assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
      end
    end

    test "encrypt creds", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        external_id = random_string()
        port = Enum.random(5000..9000)
        attrs = default_tenant_attrs(port)

        Containers.initialize_no_tenant(external_id, port)
        on_exit(fn -> Containers.stop_container(external_id) end)

        conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)

        [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]

        assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
        assert Crypto.encrypt!("postgres") == settings["db_name"]
        assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
        refute settings["db_password"]

        %{extensions: [%{settings: settings}]} = Tenants.get_tenant_by_external_id(external_id)

        assert Crypto.encrypt!("postgres") == settings["db_password"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = put(conn, ~p"/api/tenants/#{random_string()}", tenant: @invalid_attrs)
        assert json_response(conn, 422)["errors"] != %{}
      end
    end

    test "returns 403 when jwt is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:error, "invalid"} end do
        conn = put(conn, ~p"/api/tenants/external_id", tenant: @default_tenant_attrs)
        assert response(conn, 403)
      end
    end

    test "run migrations on creation", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        external_id = random_string()
        port = Enum.random(5500..9000)
        Containers.initialize_no_tenant(external_id, port)
        on_exit(fn -> Containers.stop_container(external_id) end)

        assert nil == Tenants.get_tenant_by_external_id(external_id)

        conn =
          put(conn, Routes.tenant_path(conn, :update, external_id), tenant: default_tenant_attrs(port))

        assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

        tenant = Tenants.get_tenant_by_external_id(external_id)

        {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
        assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])
      end
    end
  end

  describe "update tenant" do
    setup do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true, true)
      {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(1000)
      on_exit(fn -> Containers.stop_container(tenant) end)
      %{tenant: tenant}
    end

    test "renders tenant when data is valid", %{
      conn: conn,
      tenant: %Tenant{id: id, external_id: ext_id} = _tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = put(conn, ~p"/api/tenants/#{ext_id}", tenant: @update_attrs)
        assert %{"id" => ^id, "external_id" => ^ext_id} = json_response(conn, 200)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))
        assert "some updated name" = json_response(conn, 200)["data"]["name"]
        assert 300 = json_response(conn, 200)["data"]["max_concurrent_users"]
        assert 150 = json_response(conn, 200)["data"]["max_channels_per_client"]
        assert 250 = json_response(conn, 200)["data"]["max_events_per_second"]
        assert 50 = json_response(conn, 200)["data"]["max_joins_per_second"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = put(conn, ~p"/api/tenants/#{tenant.external_id}", tenant: @invalid_attrs)
        assert json_response(conn, 422)["errors"] != %{}
      end
    end

    test "returns 404 when jwt is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:error, "invalid"} end do
        conn = put(conn, ~p"/api/tenants", tenant: @default_tenant_attrs)
        assert json_response(conn, 404) == "Not Found"
      end
    end
  end

  describe "delete tenant" do
    setup do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true, true)
      {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(1000)
      on_exit(fn -> Containers.stop_container(tenant) end)
      %{tenant: tenant}
    end

    test "deletes chosen tenant", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        assert Cache.get_tenant_by_external_id(tenant.external_id)
        {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

        %{rows: [rows]} =
          Postgrex.query!(db_conn, "SELECT slot_name FROM pg_replication_slots", [])

        assert rows > 0
        conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}")
        assert response(conn, 204)

        refute Cache.get_tenant_by_external_id(tenant.external_id)
        refute Tenants.get_tenant_by_external_id(tenant.external_id)

        assert {:ok, %{rows: []}} =
                 Postgrex.query(db_conn, "SELECT slot_name FROM pg_replication_slots", [])
      end
    end

    test "tenant doesn't exist", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = delete(conn, ~p"/api/tenants/nope")
        assert response(conn, 204)
      end
    end

    test "returns 404 when jwt is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:error, "invalid"} end do
        conn = delete(conn, ~p"/api/tenants")
        assert json_response(conn, 404) == "Not Found"
      end
    end
  end

  describe "reload tenant" do
    setup [:create_tenant]

    test "reload when tenant does exist", %{conn: conn, tenant: tenant} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        %{status: status} = post(conn, ~p"/api/tenants/#{tenant.external_id}/reload")
        assert status == 204
      end
    end

    test "reload when tenant does not exist", %{conn: conn} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        %{status: status} = post(conn, ~p"/api/tenants/nope/reload")
        assert status == 404
      end
    end

    test "returns 404 when jwt is invalid", %{conn: conn, tenant: tenant} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:error, "invalid"} end do
        conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}/reload")
        assert json_response(conn, 404) == "Not Found"
      end
    end
  end

  describe "health check tenant" do
    setup [:create_tenant]

    setup do
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, nil) end)
    end

    test "health check when tenant does not exist", %{conn: conn} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        %{status: status} = get(conn, ~p"/api/tenants/nope/health")
        assert status == 404
      end
    end

    test "healthy tenant with 0 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: external_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = get(conn, ~p"/api/tenants/#{external_id}/health")
        data = json_response(conn, 200)["data"]
        Connect.shutdown(external_id)

        assert %{
                 "healthy" => true,
                 "db_connected" => false,
                 "connected_cluster" => 0,
                 "region" => "us-east-1",
                 "node" => "#{node()}"
               } == data
      end
    end

    test "unhealthy tenant with 1 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        # Fake adding a connected client here
        # No connection to the tenant database
        UsersCounter.add(self(), ext_id)

        conn = get(conn, ~p"/api/tenants/#{ext_id}/health")
        data = json_response(conn, 200)["data"]

        assert %{
                 "healthy" => false,
                 "db_connected" => false,
                 "connected_cluster" => 1,
                 "region" => "us-east-1",
                 "node" => "#{node()}"
               } == data
      end
    end

    test "healthy tenant with 1 client connection", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        {:ok, db_conn} = Connect.lookup_or_start_connection(ext_id)
        # Fake adding a connected client here
        UsersCounter.add(self(), ext_id)

        # Fake a db connection
        :syn.register(Realtime.Tenants.Connect, ext_id, self(), %{conn: nil})

        :syn.update_registry(Realtime.Tenants.Connect, ext_id, fn _pid, meta ->
          %{meta | conn: db_conn}
        end)

        conn = get(conn, ~p"/api/tenants/#{ext_id}/health")
        data = json_response(conn, 200)["data"]

        assert %{
                 "healthy" => true,
                 "db_connected" => true,
                 "connected_cluster" => 1,
                 "region" => "us-east-1",
                 "node" => "#{node()}"
               } == data
      end
    end

    test "returns 404 when jwt is invalid", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:error, "invalid"} end do
        conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}/health")
        assert json_response(conn, 404) == "Not Found"
      end
    end
  end

  defp create_tenant(_) do
    tenant = Containers.checkout_tenant(true)
    on_exit(fn -> Containers.checkin_tenant(tenant) end)
    %{tenant: tenant}
  end

  defp default_tenant_attrs(port) do
    %{
      "extensions" => [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "#{port}",
            "poll_interval" => 100,
            "poll_max_changes" => 100,
            "poll_max_record_bytes" => 1_048_576,
            "region" => "us-east-1",
            "ssl_enforced" => false
          }
        }
      ],
      "postgres_cdc_default" => "postgres_cdc_rls",
      "jwt_secret" => "new secret"
    }
  end
end
