defmodule RealtimeWeb.TenantControllerTest do
  # Can't run async true because under the hood Cachex is used and it doesn't see Ecto.Sandbox
  # Also using global otel_simple_processor
  use RealtimeWeb.ConnCase, async: false

  require OpenTelemetry.Tracer, as: Tracer

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

    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    {:ok, conn: conn}
  end

  defp with_tenant(_context) do
    tenant = Containers.checkout_tenant(run_migrations: true)
    %{tenant: tenant}
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

    test "sets appropriate observability metadata", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id

      # opentelemetry_phoenix expects to be a child of the originating cowboy process hence the Task here :shrug:
      Tracer.with_span "test" do
        Task.async(fn ->
          get(conn, ~p"/api/tenants/#{external_id}")

          assert Logger.metadata()[:external_id] == external_id
          assert Logger.metadata()[:project] == external_id
        end)
        |> Task.await()
      end

      assert_receive {:span, span(name: "GET /api/tenants/:tenant_id", attributes: attributes)}

      assert attributes(map: %{external_id: ^external_id}) = attributes
    end
  end

  describe "create tenant with post" do
    test "run migrations on creation and encrypts credentials", %{conn: conn} do
      external_id = random_string()
      {:ok, port} = Containers.checkout()

      assert nil == Tenants.get_tenant_by_external_id(external_id)

      attrs = default_tenant_attrs(port)
      attrs = Map.put(attrs, "external_id", external_id)

      conn = post(conn, ~p"/api/tenants", tenant: attrs)

      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]

      [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]

      assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
      assert Crypto.encrypt!("postgres") == settings["db_name"]
      assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
      refute settings["db_password"]
      Process.sleep(100)
      %{extensions: [%{settings: settings}]} = tenant = Tenants.get_tenant_by_external_id(external_id)

      assert Crypto.encrypt!("postgres") == settings["db_password"]

      assert tenant.migrations_ran > 0
    end
  end

  describe "create tenant with put" do
    test "run migrations on creation and encrypts credentials", %{conn: conn} do
      external_id = random_string()
      {:ok, port} = Containers.checkout()

      assert nil == Tenants.get_tenant_by_external_id(external_id)

      attrs = default_tenant_attrs(port)

      conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)

      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 201)["data"]
      [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]

      assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
      assert Crypto.encrypt!("postgres") == settings["db_name"]
      assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
      refute settings["db_password"]
      Process.sleep(100)
      %{extensions: [%{settings: settings}]} = tenant = Tenants.get_tenant_by_external_id(external_id)

      assert Crypto.encrypt!("postgres") == settings["db_password"]
      assert tenant.migrations_ran > 0
    end
  end

  describe "upsert with post" do
    setup [:with_tenant]

    test "renders tenant when data is valid", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id
      port = Database.from_tenant(tenant, "realtime_test", :stop).port
      attrs = default_tenant_attrs(port)
      attrs = Map.put(attrs, "external_id", external_id)
      conn = post(conn, ~p"/api/tenants", tenant: attrs)
      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.tenant_path(conn, :show, external_id))
      assert ^external_id = json_response(conn, 200)["data"]["external_id"]
      assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
      assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
      assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
      assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
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

    test "renders tenant when data is valid", %{tenant: tenant, conn: conn} do
      external_id = tenant.external_id
      port = Database.from_tenant(tenant, "realtime_test", :stop).port
      attrs = default_tenant_attrs(port)

      conn = put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)
      assert %{"id" => _id, "external_id" => ^external_id} = json_response(conn, 200)["data"]

      conn = get(conn, Routes.tenant_path(conn, :show, external_id))
      assert ^external_id = json_response(conn, 200)["data"]["external_id"]
      assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
      assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
      assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
      assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
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

    test "sets appropriate observability metadata", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id
      port = Database.from_tenant(tenant, "realtime_test", :stop).port
      attrs = default_tenant_attrs(port)

      # opentelemetry_phoenix expects to be a child of the originating cowboy process hence the Task here :shrug:
      Tracer.with_span "test" do
        Task.async(fn ->
          put(conn, ~p"/api/tenants/#{external_id}", tenant: attrs)

          assert Logger.metadata()[:external_id] == external_id
          assert Logger.metadata()[:project] == external_id
        end)
        |> Task.await()
      end

      assert_receive {:span, span(name: "PUT /api/tenants/:tenant_id", attributes: attributes)}

      assert attributes(map: %{external_id: ^external_id}) = attributes
    end
  end

  describe "delete tenant" do
    setup [:with_tenant]

    test "deletes chosen tenant", %{conn: conn, tenant: tenant} do
      {:ok, _pid} = Connect.lookup_or_start_connection(tenant.external_id)
      assert Connect.ready?(tenant.external_id)

      assert Cache.get_tenant_by_external_id(tenant.external_id)
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)

      %{rows: [rows]} =
        Postgrex.query!(db_conn, "SELECT slot_name FROM pg_replication_slots", [])

      assert rows > 0
      conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}")
      assert response(conn, 204)

      refute Cache.get_tenant_by_external_id(tenant.external_id)
      refute Tenants.get_tenant_by_external_id(tenant.external_id)
      Process.sleep(500)

      assert {:ok, %{rows: []}} =
               Postgrex.query(db_conn, "SELECT slot_name FROM pg_replication_slots", [])
    end

    test "tenant doesn't exist", %{conn: conn} do
      conn = delete(conn, ~p"/api/tenants/nope")
      assert response(conn, 204)
    end

    test "returns 403 when jwt is invalid", %{conn: conn, tenant: tenant} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = delete(conn, ~p"/api/tenants/#{tenant.external_id}")
      assert response(conn, 403) == ""
    end

    test "sets appropriate observability metadata", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id

      # opentelemetry_phoenix expects to be a child of the originating cowboy process hence the Task here :shrug:
      Tracer.with_span "test" do
        Task.async(fn ->
          delete(conn, ~p"/api/tenants/#{external_id}")

          assert Logger.metadata()[:external_id] == external_id
          assert Logger.metadata()[:project] == external_id
        end)
        |> Task.await()
      end

      assert_receive {:span, span(name: "DELETE /api/tenants/:tenant_id", attributes: attributes)}

      assert attributes(map: %{external_id: ^external_id}) = attributes
    end
  end

  describe "reload tenant" do
    setup [:with_tenant]

    test "reload when tenant does exist", %{conn: conn, tenant: %{external_id: external_id} = tenant} do
      Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> external_id)

      [%{settings: settings}] = tenant.extensions
      settings = Map.put(settings, "id", external_id)
      {:ok, _} = Extensions.PostgresCdcRls.start(settings)
      wait_on_postgres_cdc_rls(external_id)

      {:ok, manager_pid, _} = Extensions.PostgresCdcRls.get_manager_conn(external_id)
      {:ok, connect_pid} = Connect.lookup_or_start_connection(external_id)
      Process.monitor(manager_pid)
      Process.monitor(connect_pid)

      assert Process.alive?(manager_pid)
      assert Process.alive?(connect_pid)

      %{status: status} = post(conn, ~p"/api/tenants/#{external_id}/reload")

      assert status == 204

      assert_receive :disconnect
      assert_receive {:DOWN, _, :process, ^manager_pid, _}
      assert_receive {:DOWN, _, :process, ^connect_pid, _}

      refute Process.alive?(manager_pid)
      refute Process.alive?(connect_pid)
    end

    test "reload when tenant does not exist", %{conn: conn} do
      %{status: status} = post(conn, ~p"/api/tenants/nope/reload")
      assert status == 404
    end

    test "returns 403 when jwt is invalid", %{conn: conn, tenant: tenant} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = post(conn, ~p"/api/tenants/#{tenant.external_id}/reload")
      assert response(conn, 403) == ""
    end

    test "sets appropriate observability metadata", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id

      # opentelemetry_phoenix expects to be a child of the originating cowboy process hence the Task here :shrug:
      Tracer.with_span "test" do
        Task.async(fn ->
          post(conn, ~p"/api/tenants/#{tenant.external_id}/reload")

          assert Logger.metadata()[:external_id] == external_id
          assert Logger.metadata()[:project] == external_id
        end)
        |> Task.await()
      end

      assert_receive {:span, span(name: "POST /api/tenants/:tenant_id/reload", attributes: attributes)}

      assert attributes(map: %{external_id: ^external_id}) = attributes
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

    test "returns 403 when jwt is invalid", %{conn: conn, tenant: tenant} do
      conn = put_req_header(conn, "authorization", "Bearer potato")
      conn = get(conn, ~p"/api/tenants/#{tenant.external_id}/health")
      assert response(conn, 403) == ""
    end

    test "runs migrations", %{conn: conn} do
      tenant = Containers.checkout_tenant(run_migrations: false)

      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      assert {:error, _} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

      conn = get(conn, ~p"/api/tenants/#{tenant.external_id}/health")
      data = json_response(conn, 200)["data"]
      Process.sleep(2000)

      assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

      assert %{"healthy" => true, "db_connected" => false, "connected_cluster" => 0} = data
    end

    test "sets appropriate observability metadata", %{conn: conn, tenant: tenant} do
      external_id = tenant.external_id
      # opentelemetry_phoenix expects to be a child of the originating cowboy process hence the Task here :shrug:
      Tracer.with_span "test" do
        Task.async(fn ->
          get(conn, ~p"/api/tenants/#{tenant.external_id}/health")

          assert Logger.metadata()[:external_id] == external_id
          assert Logger.metadata()[:project] == external_id
        end)
        |> Task.await()
      end

      assert_receive {:span, span(name: "GET /api/tenants/:tenant_id/health", attributes: attributes)}

      assert attributes(map: %{external_id: ^external_id}) = attributes
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

  defp wait_on_postgres_cdc_rls(external_id, attempt \\ 10)

  defp wait_on_postgres_cdc_rls(external_id, 0) do
    raise "Postgres CDC RLS manager connection not established for #{external_id} after multiple attempts"
  end

  defp wait_on_postgres_cdc_rls(external_id, attempt) do
    case Extensions.PostgresCdcRls.get_manager_conn(external_id) do
      {:ok, _, _} ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        wait_on_postgres_cdc_rls(external_id, attempt - 1)
    end
  end
end
