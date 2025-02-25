defmodule Realtime.DatabaseTest do
  # async: false due to usage of mocks
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog

  alias Realtime.Database
  doctest Realtime.Database
  def handle_telemetry(event, metadata, _, pid: pid), do: send(pid, {event, metadata})

  setup do
    tenant = Containers.checkout_tenant()
    :telemetry.attach(__MODULE__, [:realtime, :database, :transaction], &__MODULE__.handle_telemetry/4, pid: self())

    on_exit(fn ->
      :telemetry.detach(__MODULE__)
      Containers.checkin_tenant(tenant)
    end)

    %{tenant: tenant}
  end

  describe "check_tenant_connection/1" do
    setup context do
      port = Enum.random(5500..9000)

      extensions = [
        %{
          "type" => "postgres_cdc_rls",
          "settings" => %{
            "db_host" => "127.0.0.1",
            "db_name" => "postgres",
            "db_user" => "supabase_admin",
            "db_password" => "postgres",
            "db_port" => "#{port}",
            "region" => "us-east-1",
            "ssl_enforced" => false,
            "db_pool" => Map.get(context, :db_pool),
            "subcriber_pool_size" => Map.get(context, :subcriber_pool),
            "subs_pool_size" => Map.get(context, :db_pool)
          }
        }
      ]

      tenant = tenant_fixture(%{extensions: extensions})
      Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)
      %{tenant: tenant}
    end

    test "connects to a tenant database", %{tenant: tenant} do
      assert {:ok, _} = Database.check_tenant_connection(tenant)
    end

    # Connection limit for docker tenant db is 100
    @tag db_pool: 50,
         subs_pool_size: 50,
         subcriber_pool_size: 50
    test "restricts connection if tenant database cannot receive more connections based on tenant pool",
         %{tenant: tenant} do
      assert {:error, :tenant_db_too_many_connections} = Database.check_tenant_connection(tenant)
    end
  end

  describe "replication_slot_teardown/1" do
    test "removes replication slots with the realtime prefix" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(
        conn,
        "SELECT * FROM pg_create_logical_replication_slot('realtime_test_slot', 'pgoutput')",
        []
      )

      Database.replication_slot_teardown(tenant)
      assert %{rows: []} = Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])
    end
  end

  describe "replication_slot_teardown/2" do
    test "removes replication slots with a given name and existing connection" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      name = String.downcase("slot_#{random_string()}")
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(
        conn,
        "SELECT * FROM pg_create_logical_replication_slot('#{name}', 'pgoutput')",
        []
      )

      Database.replication_slot_teardown(conn, name)
      Process.sleep(1000)
      assert %{rows: []} = Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])
    end

    test "removes replication slots with a given name and a tenant" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      name = String.downcase("slot_#{random_string()}")
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      Postgrex.query!(
        conn,
        "SELECT * FROM pg_create_logical_replication_slot('#{name}', 'pgoutput')",
        []
      )

      Database.replication_slot_teardown(tenant, name)
      assert %{rows: []} = Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])
    end
  end

  describe "transaction/1" do
    setup %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      %{db_conn: db_conn}
    end

    test "handles transaction errors", %{db_conn: db_conn} do
      assert {:error, %DBConnection.ConnectionError{reason: :error}} =
               Database.transaction(db_conn, fn conn ->
                 Postgrex.query!(conn, "select pg_terminate_backend(pg_backend_pid())", [])
               end)
    end

    test "on checkout error, handles raised exception as an error", %{db_conn: db_conn} do
      for _ <- 1..5 do
        Task.start(fn ->
          Database.transaction(
            db_conn,
            fn conn -> Postgrex.query!(conn, "SELECT pg_sleep(20)", []) end,
            timeout: 20000
          )
        end)
      end

      log =
        capture_log(fn ->
          assert {:error, %DBConnection.ConnectionError{reason: :queue_timeout}} =
                   Task.async(fn ->
                     Database.transaction(
                       db_conn,
                       fn conn -> Postgrex.query!(conn, "SELECT pg_sleep(11)", []) end,
                       timeout: 15000
                     )
                   end)
                   |> Task.await(20000)
        end)

      assert log =~ "ErrorExecutingTransaction"
    end

    test "run call using RPC", %{db_conn: db_conn} do
      assert {:ok, %{rows: [[1]]}} =
               Realtime.Rpc.enhanced_call(
                 node(db_conn),
                 Database,
                 :transaction,
                 [
                   db_conn,
                   fn db_conn -> Postgrex.query!(db_conn, "SELECT 1", []) end,
                   [backoff: :stop],
                   [tenant_id: "test"]
                 ]
               )
    end

    test "with telemetry event defined, emits telemetry event", %{db_conn: db_conn} do
      event = [:realtime, :database, :transaction]

      Database.transaction(
        db_conn,
        fn conn -> Postgrex.query!(conn, "SELECT pg_sleep(6)", []) end,
        telemetry: event
      )

      assert_receive {^event, %{latency: _}}
    end
  end

  describe "pool_size_by_application_name/2" do
    test "returns the number of connections per application name" do
      assert Database.pool_size_by_application_name("realtime_connect", %{}) == 1
      assert Database.pool_size_by_application_name("realtime_connect", %{"db_pool" => 10}) == 10
      assert Database.pool_size_by_application_name("realtime_potato", %{}) == 1
      assert Database.pool_size_by_application_name("realtime_rls", %{"db_pool" => 10}) == 1

      assert Database.pool_size_by_application_name("realtime_rls", %{"subs_pool_size" => 10}) ==
               1

      assert Database.pool_size_by_application_name("realtime_rls", %{"subcriber_pool_size" => 10}) ==
               1

      assert Database.pool_size_by_application_name("realtime_broadcast_changes", %{
               "db_pool" => 10
             }) == 1

      assert Database.pool_size_by_application_name("realtime_broadcast_changes", %{
               "subs_pool_size" => 10
             }) == 1

      assert Database.pool_size_by_application_name("realtime_broadcast_changes", %{
               "subcriber_pool_size" => 10
             }) == 1

      assert Database.pool_size_by_application_name("realtime_migrations", %{
               "db_pool" => 10
             }) == 2

      assert Database.pool_size_by_application_name("realtime_migrations", %{
               "subs_pool_size" => 10
             }) == 2

      assert Database.pool_size_by_application_name("realtime_migrations", %{
               "subcriber_pool_size" => 10
             }) == 2
    end
  end

  describe "get_external_id/1" do
    test "returns the external id for a given hostname" do
      assert Realtime.Database.get_external_id("tenant.realtime.supabase.co") == {:ok, "tenant"}
      assert Realtime.Database.get_external_id("tenant.supabase.co") == {:ok, "tenant"}
      assert Realtime.Database.get_external_id("localhost") == {:ok, "localhost"}
    end
  end

  describe "detect_ip_version/1" do
    test "detects appropriate IP version" do
      # Using ipv4.google.com
      assert Realtime.Database.detect_ip_version("ipv4.google.com") == {:ok, :inet}

      # Using ipv6.google.com
      assert Realtime.Database.detect_ip_version("ipv6.google.com") == {:ok, :inet6}

      # Using 2001:0db8:85a3:0000:0000:8a2e:0370:7334
      assert Realtime.Database.detect_ip_version("2001:0db8:85a3:0000:0000:8a2e:0370:7334") ==
               {:ok, :inet6}

      # Using 127.0.0.1
      assert Realtime.Database.detect_ip_version("127.0.0.1") == {:ok, :inet}

      # Using invalid domain
      assert Realtime.Database.detect_ip_version("potato") == {:error, :nxdomain}
    end
  end

  describe "from_settings/3" do
    test "returns struct with correct setup" do
      tenant = tenant_fixture()
      tenant = Containers.initialize(tenant, true)
      on_exit(fn -> Containers.stop_container(tenant) end)

      application_name = "realtime_connect"
      backoff = :stop
      {:ok, ip_version} = Database.detect_ip_version("127.0.0.1")
      socket_options = [ip_version]
      settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
      settings = Database.from_settings(settings, application_name, backoff)
      port = settings.port

      assert %Realtime.Database{
               socket_options: ^socket_options,
               application_name: ^application_name,
               backoff_type: ^backoff,
               hostname: "127.0.0.1",
               port: ^port,
               database: "postgres",
               username: "supabase_admin",
               password: "postgres",
               pool_size: 1,
               queue_target: 5000,
               max_restarts: nil,
               ssl: false
             } = settings
    end

    test "handles SSL properties", %{tenant: tenant} do
      application_name = "realtime_connect"
      backoff = :stop

      settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
      settings = Map.put(settings, "ssl_enforced", true)
      settings = Database.from_settings(settings, application_name, backoff)
      assert settings.ssl == [verify: :verify_none]

      settings = Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", tenant.extensions)
      settings = Map.put(settings, "ssl_enforced", false)
      settings = Database.from_settings(settings, application_name, backoff)
      assert settings.ssl == false
    end
  end
end
