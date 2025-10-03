defmodule Realtime.Extensions.CdcRlsTest do
  # async: false due to usage of dev_tenant
  # Also global mimic mock
  use RealtimeWeb.ChannelCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  setup :set_mimic_global

  alias Extensions.PostgresCdcRls
  alias PostgresCdcRls.SubscriptionManager
  alias Postgrex
  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.PostgresCdc
  alias Realtime.RateCounter
  alias Realtime.Tenants.Rebalancer

  @cdc_module Extensions.PostgresCdcRls

  describe "Postgres extensions" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)

      {:ok, conn} = Database.connect(tenant, "realtime_test")

      Database.transaction(conn, fn db_conn ->
        queries = [
          "drop table if exists public.test",
          "drop publication if exists supabase_realtime_test",
          "create sequence if not exists test_id_seq;",
          """
          create table if not exists "public"."test" (
          "id" int4 not null default nextval('test_id_seq'::regclass),
          "details" text,
          primary key ("id"));
          """,
          "grant all on table public.test to anon;",
          "grant all on table public.test to postgres;",
          "grant all on table public.test to authenticated;",
          "create publication supabase_realtime_test for all tables"
        ]

        Enum.each(queries, &Postgrex.query!(db_conn, &1, []))
      end)

      %Tenant{extensions: extensions, external_id: external_id} = tenant
      postgres_extension = PostgresCdc.filter_settings("postgres_cdc_rls", extensions)
      args = Map.put(postgres_extension, "id", external_id)

      pg_change_params = [
        %{
          id: UUID.uuid1(),
          params: %{"event" => "*", "schema" => "public"},
          channel_pid: self(),
          claims: %{
            "exp" => System.system_time(:second) + 100_000,
            "iat" => 0,
            "ref" => "127.0.0.1",
            "role" => "anon"
          }
        }
      ]

      ids =
        Enum.map(pg_change_params, fn %{id: id, params: params} ->
          {UUID.string_to_binary!(id), :erlang.phash2(params)}
        end)

      topic = "realtime:test"
      serializer = Phoenix.Socket.V1.JSONSerializer

      subscription_metadata = {:subscriber_fastlane, self(), serializer, ids, topic, external_id, true}
      metadata = [metadata: subscription_metadata]
      :ok = PostgresCdc.subscribe(PostgresCdcRls, pg_change_params, external_id, metadata)

      # First time it will return nil
      PostgresCdcRls.handle_connect(args)
      # Wait for it to start
      Process.sleep(3000)
      {:ok, response} = PostgresCdcRls.handle_connect(args)

      # Now subscribe to the Postgres Changes
      {:ok, _} = PostgresCdcRls.handle_after_connect(response, postgres_extension, pg_change_params)

      on_exit(fn -> PostgresCdcRls.handle_stop(external_id, 10_000) end)
      %{tenant: tenant}
    end

    @tag skip: "Flaky test. When logger handle_sasl_reports is enabled this test doesn't break"
    test "Check supervisor crash and respawn", %{tenant: tenant} do
      sup =
        Enum.reduce_while(1..30, nil, fn _, acc ->
          :syn.lookup(Extensions.PostgresCdcRls, tenant.external_id)
          |> case do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            {pid, _} when is_pid(pid) ->
              {:halt, pid}
          end
        end)

      assert Process.alive?(sup)
      Process.monitor(sup)

      RealtimeWeb.Endpoint.subscribe(PostgresCdcRls.syn_topic(tenant.external_id))

      Process.exit(sup, :kill)
      assert_receive {:DOWN, _, :process, ^sup, _reason}, 5000

      assert_receive %{event: "ready"}, 5000

      {sup2, _} = :syn.lookup(Extensions.PostgresCdcRls, tenant.external_id)

      assert(sup != sup2)
      assert Process.alive?(sup2)
    end

    test "Subscription manager updates oids", %{tenant: tenant} do
      {subscriber_manager_pid, conn} =
        Enum.reduce_while(1..25, nil, fn _, acc ->
          case PostgresCdcRls.get_manager_conn(tenant.external_id) do
            nil ->
              Process.sleep(200)
              {:cont, acc}

            {:error, :wait} ->
              Process.sleep(200)
              {:cont, acc}

            {:ok, pid, conn} ->
              {:halt, {pid, conn}}
          end
        end)

      %SubscriptionManager.State{oids: oids} = :sys.get_state(subscriber_manager_pid)

      Postgrex.query!(conn, "drop publication if exists supabase_realtime_test", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids2} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids, oids2)

      Postgrex.query!(conn, "create publication supabase_realtime_test for all tables", [])
      send(subscriber_manager_pid, :check_oids)
      %{oids: oids3} = :sys.get_state(subscriber_manager_pid)
      assert !Map.equal?(oids2, oids3)
    end

    test "Stop tenant supervisor", %{tenant: tenant} do
      sup =
        Enum.reduce_while(1..10, nil, fn _, acc ->
          case :syn.lookup(Extensions.PostgresCdcRls, tenant.external_id) do
            :undefined ->
              Process.sleep(500)
              {:cont, acc}

            {pid, _} ->
              {:halt, pid}
          end
        end)

      assert Process.alive?(sup)
      PostgresCdc.stop(@cdc_module, tenant)
      assert Process.alive?(sup) == false
    end
  end

  describe "Region rebalancing" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)
      %Tenant{extensions: extensions, external_id: external_id} = tenant
      postgres_extension = PostgresCdc.filter_settings("postgres_cdc_rls", extensions)

      args =
        postgres_extension
        |> Map.put("id", external_id)
        |> Map.put(:check_region_interval, 100)

      %{tenant_id: tenant.external_id, args: args}
    end

    test "rebalancing needed process stops", %{tenant_id: tenant_id, args: args} do
      log =
        capture_log(fn ->
          expect(Rebalancer, :check, fn _, _, ^tenant_id -> {:error, :wrong_region} end)

          {:ok, pid} = PostgresCdcRls.start(args)
          ref = Process.monitor(pid)

          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 3000
        end)

      assert log =~ "Rebalancing Postgres Changes replication for a closer region"
    end

    test "rebalancing not needed process stays up", %{tenant_id: tenant_id, args: args} do
      stub(Rebalancer, :check, fn _, _, ^tenant_id -> :ok end)

      {:ok, pid} = PostgresCdcRls.start(args)
      ref = Process.monitor(pid)

      refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000
    end
  end

  describe "integration" do
    setup do
      tenant = Api.get_tenant_by_external_id("dev_tenant")
      PostgresCdcRls.handle_stop(tenant.external_id, 10_000)

      {:ok, conn} = Database.connect(tenant, "realtime_test")

      Database.transaction(conn, fn db_conn ->
        queries = [
          "drop table if exists public.test",
          "drop publication if exists supabase_realtime_test",
          "create sequence if not exists test_id_seq;",
          """
          create table if not exists "public"."test" (
          "id" int4 not null default nextval('test_id_seq'::regclass),
          "details" text,
          primary key ("id"));
          """,
          "grant all on table public.test to anon;",
          "grant all on table public.test to postgres;",
          "grant all on table public.test to authenticated;",
          "create publication supabase_realtime_test for all tables"
        ]

        Enum.each(queries, &Postgrex.query!(db_conn, &1, []))
      end)

      RateCounter.stop(tenant.external_id)

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      :telemetry.attach(
        __MODULE__,
        [:realtime, :tenants, :payload, :size],
        &__MODULE__.handle_telemetry/4,
        pid: self()
      )

      %{tenant: tenant, conn: conn}
    end

    test "subscribe inserts", %{tenant: tenant, conn: conn} do
      on_exit(fn -> PostgresCdcRls.handle_stop(tenant.external_id, 10_000) end)

      %Tenant{extensions: extensions, external_id: external_id} = tenant
      postgres_extension = PostgresCdc.filter_settings("postgres_cdc_rls", extensions)
      args = Map.put(postgres_extension, "id", external_id)

      pg_change_params = [
        %{
          id: UUID.uuid1(),
          params: %{"event" => "*", "schema" => "public"},
          channel_pid: self(),
          claims: %{
            "exp" => System.system_time(:second) + 100_000,
            "iat" => 0,
            "ref" => "127.0.0.1",
            "role" => "anon"
          }
        }
      ]

      ids =
        Enum.map(pg_change_params, fn %{id: id, params: params} ->
          {UUID.string_to_binary!(id), :erlang.phash2(params)}
        end)

      topic = "realtime:test"
      serializer = Phoenix.Socket.V1.JSONSerializer

      subscription_metadata = {:subscriber_fastlane, self(), serializer, ids, topic, external_id, true}
      metadata = [metadata: subscription_metadata]
      :ok = PostgresCdc.subscribe(PostgresCdcRls, pg_change_params, external_id, metadata)

      # First time it will return nil
      PostgresCdcRls.handle_connect(args)
      # Wait for it to start
      Process.sleep(3000)
      {:ok, response} = PostgresCdcRls.handle_connect(args)

      # Now subscribe to the Postgres Changes
      {:ok, _} = PostgresCdcRls.handle_after_connect(response, postgres_extension, pg_change_params)
      assert %Postgrex.Result{rows: [[1]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

      # Insert a record
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])

      assert_receive {:socket_push, :text, data}, 5000

      message =
        data
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      assert %{
               "event" => "postgres_changes",
               "payload" => %{
                 "data" => %{
                   "columns" => [%{"name" => "id", "type" => "int4"}, %{"name" => "details", "type" => "text"}],
                   "commit_timestamp" => _,
                   "errors" => nil,
                   "record" => %{"details" => "test", "id" => ^id},
                   "schema" => "public",
                   "table" => "test",
                   "type" => "INSERT"
                 },
                 "ids" => _
               },
               "ref" => nil,
               "topic" => "realtime:test"
             } = message

      # Wait for RateCounter to update
      Process.sleep(2000)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)

      assert {:ok, %RateCounter{id: {:channel, :db_events, "dev_tenant"}, bucket: bucket}} = RateCounter.get(rate)
      assert 1 in bucket

      assert_receive {
        :telemetry,
        [:realtime, :tenants, :payload, :size],
        %{size: 341},
        %{tenant: "dev_tenant", message_type: :postgres_changes}
      }
    end

    @aux_mod (quote do
                defmodule Subscriber do
                  # Start CDC remotely
                  def subscribe(tenant) do
                    %Tenant{extensions: extensions, external_id: external_id} = tenant
                    postgres_extension = PostgresCdc.filter_settings("postgres_cdc_rls", extensions)
                    args = Map.put(postgres_extension, "id", external_id)

                    # Boot it
                    PostgresCdcRls.start(args)
                    # Wait for it to start
                    Process.sleep(3000)
                    {:ok, manager, conn} = PostgresCdcRls.get_manager_conn(external_id)
                    {:ok, {manager, conn}}
                  end
                end
              end)

    test "subscribe inserts distributed mode", %{tenant: tenant, conn: conn} do
      {:ok, node} = Clustered.start(@aux_mod)
      {:ok, response} = :erpc.call(node, Subscriber, :subscribe, [tenant])

      %Tenant{extensions: extensions, external_id: external_id} = tenant
      postgres_extension = PostgresCdc.filter_settings("postgres_cdc_rls", extensions)

      pg_change_params = [
        %{
          id: UUID.uuid1(),
          params: %{"event" => "*", "schema" => "public"},
          channel_pid: self(),
          claims: %{
            "exp" => System.system_time(:second) + 100_000,
            "iat" => 0,
            "ref" => "127.0.0.1",
            "role" => "anon"
          }
        }
      ]

      ids =
        Enum.map(pg_change_params, fn %{id: id, params: params} ->
          {UUID.string_to_binary!(id), :erlang.phash2(params)}
        end)

      # Subscribe to the topic as a websocket client
      topic = "realtime:test"
      serializer = Phoenix.Socket.V1.JSONSerializer

      subscription_metadata = {:subscriber_fastlane, self(), serializer, ids, topic, external_id, true}
      metadata = [metadata: subscription_metadata]
      :ok = PostgresCdc.subscribe(PostgresCdcRls, pg_change_params, external_id, metadata)

      # Now subscribe to the Postgres Changes
      {:ok, _} = PostgresCdcRls.handle_after_connect(response, postgres_extension, pg_change_params)
      assert %Postgrex.Result{rows: [[1]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

      # Insert a record
      %{rows: [[id]]} = Postgrex.query!(conn, "insert into test (details) values ('test') returning id", [])

      assert_receive {:socket_push, :text, data}, 5000

      message =
        data
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      assert %{
               "event" => "postgres_changes",
               "payload" => %{
                 "data" => %{
                   "columns" => [%{"name" => "id", "type" => "int4"}, %{"name" => "details", "type" => "text"}],
                   "commit_timestamp" => _,
                   "errors" => nil,
                   "record" => %{"details" => "test", "id" => ^id},
                   "schema" => "public",
                   "table" => "test",
                   "type" => "INSERT"
                 },
                 "ids" => _
               },
               "ref" => nil,
               "topic" => "realtime:test"
             } = message

      # Wait for RateCounter to update
      Process.sleep(2000)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)

      assert {:ok, %RateCounter{id: {:channel, :db_events, "dev_tenant"}, bucket: bucket}} = RateCounter.get(rate)
      assert 1 in bucket

      :erpc.call(node, PostgresCdcRls, :handle_stop, [tenant.external_id, 10_000])
    end
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {:telemetry, event, measures, metadata})
end
