defmodule RealtimeWeb.TenantControllerTest do
  use RealtimeWeb.ConnCase, async: false

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.PromEx.Plugins.Tenants
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

  @invalid_attrs %{external_id: nil, jwt_secret: nil, extensions: [], name: nil}

  setup context do
    %{conn: conn} = context
    key = Application.get_env(:realtime, :api_jwt_secret)
    jwt = generate_jwt_token(key)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{jwt}")

    {:ok, conn: conn}
  end

  defp with_tenant(context) do
    tenant = Containers.checkout_tenant(true)
    on_exit(fn -> Containers.checkin_tenant(tenant) end)
    Map.put(context, :tenant, tenant)
  end

  describe "show tenant" do
    setup [:with_tenant]

    test "removes db_password", %{conn: conn, tenant: tenant} do
      conn = get(conn, ~p"/api/tenants/#{tenant.external_id}")
      response = json_response(conn, 200)
      refute get_in(response, ["data", "extensions", Access.at(0), "settings", "db_password"])
    end

    test "returns not found on non existing tenant", %{conn: conn} do
      conn = get(conn, ~p"/api/tenants/no")
      response = json_response(conn, 404)
      assert response == %{"error" => "not found"}
    end
  end

  describe "create tenant with post" do
    test "run migrations on creation", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)
      assert nil == Tenants.get_tenant_by_external_id(external_id)

      attrs = default_tenant_attrs(port)
      attrs = Map.put(attrs, "external_id", external_id)

      conn = post(conn, ~p"/api/tenants", tenant: attrs)

      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

      tenant = Tenants.get_tenant_by_external_id(external_id)
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])
    end
  end

  describe "create tenant with put" do
    test "run migrations on creation", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)
      assert nil == Tenants.get_tenant_by_external_id(external_id)

      attrs = default_tenant_attrs(port)

      conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)

      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

      tenant = Tenants.get_tenant_by_external_id(external_id)
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])
    end
  end

  describe "upsert with post" do
    test "renders tenant when data is valid", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      attrs = default_tenant_attrs(port)
      attrs = Map.put(attrs, "external_id", external_id)

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)

      conn = post(conn, ~p"/api/tenants", tenant: attrs)
      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

      conn = get(conn, Routes.tenant_path(conn, :show, external_id))
      assert ^external_id = json_response(conn, 200)["data"]["external_id"]
      assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
      assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
      assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
      assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
    end

    test "encrypt creds", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)

      attrs = default_tenant_attrs(port)
      attrs = Map.put(attrs, "external_id", external_id)
      conn = post(conn, ~p"/api/tenants", tenant: attrs)

      [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]

      assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
      assert Crypto.encrypt!("postgres") == settings["db_name"]
      assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
      refute settings["db_password"]

      %{extensions: [%{settings: settings}]} = Tenants.get_tenant_by_external_id(external_id)

      assert Crypto.encrypt!("postgres") == settings["db_password"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/tenants", tenant: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 403 when jwt is invalid", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = post(conn, ~p"/api/tenants", tenant: default_tenant_attrs(5000))
      assert response(conn, 403)
    end
  end

  describe "upsert with put" do
    setup [:with_tenant]

    test "renders tenant when data is valid", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      :ets.insert(:test_ports, {port})

      attrs = default_tenant_attrs(port)

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)

      conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)
      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

      conn = get(conn, Routes.tenant_path(conn, :show, external_id))
      assert ^external_id = json_response(conn, 200)["data"]["external_id"]
      assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
      assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
      assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
      assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
    end

    test "encrypt creds", %{conn: conn} do
      external_id = random_string()

      port =
        5500..9000
        |> Enum.reject(&(&1 in Enum.map(:ets.tab2list(:test_ports), fn {port} -> port end)))
        |> Enum.random()

      Containers.initialize_no_tenant(external_id, port)
      on_exit(fn -> Containers.stop_container(external_id) end)

      attrs = default_tenant_attrs(port)
      conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)

      [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]

      assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
      assert Crypto.encrypt!("postgres") == settings["db_name"]
      assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
      refute settings["db_password"]

      %{extensions: [%{settings: settings}]} = Tenants.get_tenant_by_external_id(external_id)

      assert Crypto.encrypt!("postgres") == settings["db_password"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = put(conn, ~p"/api/tenants/#{random_string()}", tenant: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end

    test "returns 403 when jwt is invalid", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = put(conn, ~p"/api/tenants/external_id", tenant: default_tenant_attrs(5000))
      assert response(conn, 403)
    end
  end

  describe "delete tenant" do
    setup do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true, true)
      on_exit(fn -> Containers.stop_container(tenant) end)
      %{tenant: tenant}
    end

    test "deletes chosen tenant", %{conn: conn, tenant: tenant} do
      {:ok, _pid} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
      Process.sleep(500)
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

    test "tenant doesn't exist", %{conn: conn} do
      conn = delete(conn, ~p"/api/tenants/nope")
      assert response(conn, 204)
    end

    test "returns 404 when jwt is invalid", %{conn: conn} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = delete(conn, ~p"/api/tenants")
      assert json_response(conn, 404) == "Not Found"
    end
  end

  describe "reload tenant" do
    setup [:with_tenant]

    test "reload when tenant does exist", %{conn: conn, tenant: tenant} do
      %{status: status} = post(conn, ~p"/api/tenants/#{tenant.external_id}/reload")
      assert status == 204
    end

    test "reload when tenant does not exist", %{conn: conn} do
      %{status: status} = post(conn, ~p"/api/tenants/nope/reload")
      assert status == 404
    end

    test "returns 404 when jwt is invalid", %{conn: conn, tenant: tenant} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}/reload")
      assert json_response(conn, 404) == "Not Found"
    end
  end

  describe "health check tenant" do
    setup [:with_tenant]

    setup do
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, nil) end)
    end

    test "health check when tenant does not exist", %{conn: conn} do
      %{status: status} = get(conn, ~p"/api/tenants/nope/health")
      assert status == 404
    end

    test "healthy tenant with 0 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: external_id}
    } do
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

    test "unhealthy tenant with 1 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
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

    test "healthy tenant with 1 client connection", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
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

    test "returns 404 when jwt is invalid", %{conn: conn, tenant: tenant} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}/health")
      assert json_response(conn, 404) == "Not Found"
    end

    test "runs migrations", %{conn: conn} do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      assert {:error, _} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

      conn = get(conn, ~p"/api/tenants/#{tenant.external_id}/health")
      data = json_response(conn, 200)["data"]
      Process.sleep(2000)

      assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

      assert %{"healthy" => true, "db_connected" => false, "connected_cluster" => 0} = data
    end
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
