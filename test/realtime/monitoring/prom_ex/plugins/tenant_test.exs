defmodule Realtime.PromEx.Plugins.TenantTest do
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.Tenant
  alias Realtime.PromEx.Plugins.TenantGlobal
  alias Realtime.Rpc
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.RateCounter
  alias Realtime.GenCounter

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_phoenix

    @impl true
    def plugins, do: [{Tenant, poll_rate: 50}, {TenantGlobal, poll_rate: 50}]
  end

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  def handle_telemetry(event, metadata, content, pid: pid), do: send(pid, {event, metadata, content})

  @aux_mod (quote do
              defmodule FakeUserCounter do
                def fake_add(external_id) do
                  pid = spawn(fn -> Process.sleep(2000) end)
                  :ok = Beacon.join(:users, external_id, pid)
                end

                def fake_db_event(external_id) do
                  rate = Realtime.Tenants.db_events_per_second_rate(external_id, 100)

                  rate
                  |> tap(&RateCounter.new(&1))
                  |> tap(&GenCounter.add(&1.id))
                  |> RateCounterHelper.tick!()
                end

                def fake_event(external_id) do
                  rate = Realtime.Tenants.events_per_second_rate(external_id, 123)

                  rate
                  |> tap(&RateCounter.new(&1))
                  |> tap(&GenCounter.add(&1.id))
                  |> RateCounterHelper.tick!()
                end

                def fake_presence_event(external_id) do
                  rate = Realtime.Tenants.presence_events_per_second_rate(external_id, 123)

                  rate
                  |> tap(&RateCounter.new(&1))
                  |> tap(&GenCounter.add(&1.id))
                  |> RateCounterHelper.tick!()
                end

                def fake_broadcast_from_database(external_id) do
                  Realtime.Telemetry.execute(
                    [:realtime, :tenants, :broadcast_from_database],
                    %{
                      # millisecond
                      latency_committed_at: 9,
                      # microsecond
                      latency_inserted_at: 9000
                    },
                    %{tenant: external_id}
                  )
                end

                def fake_input_bytes(external_id) do
                  Realtime.Telemetry.execute([:realtime, :channel, :input_bytes], %{size: 10}, %{tenant: external_id})
                end

                def fake_output_bytes(external_id) do
                  Realtime.Telemetry.execute([:realtime, :channel, :output_bytes], %{size: 10}, %{tenant: external_id})
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "execute_tenant_metrics/0" do
    setup do
      tenant = Containers.checkout_tenant()
      :telemetry.attach(__MODULE__, [:realtime, :connections], &__MODULE__.handle_telemetry/4, pid: self())

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
      {:ok, node} = Clustered.start(@aux_mod, extra_config: [{:realtime, :users_scope_broadcast_interval_in_ms, 50}])
      %{tenant: tenant, node: node}
    end

    test "returns a list of tenant metrics and handles bad tenant ids", %{
      tenant: %{external_id: external_id},
      node: node
    } do
      :ok = Beacon.join(:users, external_id, self())
      # Add bad tenant id
      bad_tenant_id = random_string()
      :ok = Beacon.join(:users, bad_tenant_id, self())

      _ = Rpc.call(node, FakeUserCounter, :fake_add, [external_id])

      Process.sleep(500)
      Tenant.execute_tenant_metrics()

      assert_receive {[:realtime, :connections], %{connected: 1, limit: 200, connected_cluster: 2},
                      %{tenant: ^external_id}},
                     500

      refute_receive {[:realtime, :connections], %{connected: 1, limit: 200, connected_cluster: 2},
                      %{tenant: ^bad_tenant_id}}
    end
  end

  describe "event_metrics/0" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)
      {:ok, db_conn} = Realtime.Database.connect(tenant, "realtime_test", :stop)

      authorization_context =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          topic: "test_topic",
          jwt: "jwt",
          claims: [],
          headers: [{"header-1", "value-1"}],
          role: "anon"
        })

      %{authorization_context: authorization_context, db_conn: db_conn, tenant: tenant}
    end

    test "event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_events", tenant: external_id) || 0
      FakeUserCounter.fake_event(external_id)

      Process.sleep(100)
      assert metric_value("realtime_channel_events", tenant: external_id) == metric_value + 1
    end

    test "global event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_global_events") || 0

      FakeUserCounter.fake_event(external_id)

      Process.sleep(100)
      assert metric_value("realtime_channel_global_events") == metric_value + 1
    end

    test "db_event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_db_events", tenant: external_id) || 0
      FakeUserCounter.fake_db_event(external_id)
      Process.sleep(100)
      assert metric_value("realtime_channel_db_events", tenant: external_id) == metric_value + 1
    end

    test "global db_event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_global_db_events") || 0

      FakeUserCounter.fake_db_event(external_id)
      Process.sleep(100)
      assert metric_value("realtime_channel_global_db_events") == metric_value + 1
    end

    test "presence_event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_presence_events", tenant: external_id) || 0

      FakeUserCounter.fake_presence_event(external_id)
      Process.sleep(100)
      assert metric_value("realtime_channel_presence_events", tenant: external_id) == metric_value + 1
    end

    test "global presence_event exists after counter added", %{tenant: %{external_id: external_id}} do
      metric_value = metric_value("realtime_channel_global_presence_events") || 0
      FakeUserCounter.fake_presence_event(external_id)
      Process.sleep(100)
      assert metric_value("realtime_channel_global_presence_events") == metric_value + 1
    end

    test "metric read_authorization_check exists after check", context do
      metric = "realtime_tenants_read_authorization_check_count"
      metric_value = metric_value(metric, tenant: context.tenant.external_id) || 0

      {:ok, _} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      Process.sleep(200)

      assert metric_value(metric, tenant: context.tenant.external_id) == metric_value + 1

      assert metric_value("realtime_tenants_read_authorization_check_bucket",
               tenant: context.tenant.external_id,
               le: "250.0"
             ) > 0
    end

    test "metric write_authorization_check exists after check", context do
      metric = "realtime_tenants_write_authorization_check_count"
      metric_value = metric_value(metric, tenant: context.tenant.external_id) || 0

      {:ok, _} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      # Wait enough time for the poll rate to be triggered at least once
      Process.sleep(200)

      assert metric_value(metric, tenant: context.tenant.external_id) == metric_value + 1

      assert metric_value("realtime_tenants_write_authorization_check_bucket",
               tenant: context.tenant.external_id,
               le: "250.0"
             ) > 0
    end

    test "metric replay exists after check", context do
      external_id = context.tenant.external_id
      metric = "realtime_tenants_replay_count"
      metric_value = metric_value(metric, tenant: external_id) || 0

      assert {:ok, _, _} = Realtime.Messages.replay(context.db_conn, external_id, "test", 0, 1)

      # Wait enough time for the poll rate to be triggered at least once
      Process.sleep(200)

      assert metric_value(metric, tenant: external_id) == metric_value + 1

      assert metric_value("realtime_tenants_replay_bucket", tenant: external_id, le: "250.0") > 0
    end

    test "metric realtime_tenants_broadcast_from_database_latency_committed_at exists after check", context do
      external_id = context.tenant.external_id
      metric = "realtime_tenants_broadcast_from_database_latency_committed_at_count"
      metric_value = metric_value(metric, tenant: external_id) || 0

      FakeUserCounter.fake_broadcast_from_database(context.tenant.external_id)
      Process.sleep(200)
      assert metric_value(metric, tenant: external_id) == metric_value + 1

      assert metric_value("realtime_tenants_broadcast_from_database_latency_committed_at_bucket",
               tenant: external_id,
               le: "10.0"
             ) > 0
    end

    test "metric realtime_tenants_broadcast_from_database_latency_inserted_at exists after check", context do
      external_id = context.tenant.external_id
      metric = "realtime_tenants_broadcast_from_database_latency_inserted_at_count"
      metric_value = metric_value(metric, tenant: external_id) || 0

      FakeUserCounter.fake_broadcast_from_database(context.tenant.external_id)
      Process.sleep(200)
      assert metric_value(metric, tenant: external_id) == metric_value + 1

      assert metric_value("realtime_tenants_broadcast_from_database_latency_inserted_at_bucket",
               tenant: external_id,
               le: "10.0"
             ) > 0
    end

    test "tenant metric payload size", context do
      external_id = context.tenant.external_id
      metric = "realtime_tenants_payload_size_count"
      metric_value = metric_value(metric, message_type: "presence", tenant: external_id) || 0

      message = %{topic: "a topic", event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
      RealtimeWeb.TenantBroadcaster.pubsub_broadcast(external_id, "a topic", message, Phoenix.PubSub, :presence)

      Process.sleep(200)
      assert metric_value(metric, message_type: "presence", tenant: external_id) == metric_value + 1

      assert metric_value("realtime_tenants_payload_size_bucket", tenant: external_id, le: "250") > 0
    end

    test "global metric payload size", context do
      external_id = context.tenant.external_id

      metric = "realtime_payload_size_count"
      metric_value = metric_value(metric, message_type: "broadcast") || 0

      message = %{topic: "a topic", event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
      RealtimeWeb.TenantBroadcaster.pubsub_broadcast(external_id, "a topic", message, Phoenix.PubSub, :broadcast)

      Process.sleep(200)
      assert metric_value(metric, message_type: "broadcast") == metric_value + 1

      assert metric_value("realtime_payload_size_bucket", le: "250.0") > 0
    end

    test "channel input bytes", context do
      external_id = context.tenant.external_id

      FakeUserCounter.fake_input_bytes(external_id)
      FakeUserCounter.fake_input_bytes(external_id)

      Process.sleep(200)
      assert metric_value("realtime_channel_input_bytes", tenant: external_id) == 20
    end

    test "channel output bytes", context do
      external_id = context.tenant.external_id

      FakeUserCounter.fake_output_bytes(external_id)
      FakeUserCounter.fake_output_bytes(external_id)

      Process.sleep(200)
      assert metric_value("realtime_channel_output_bytes", tenant: external_id) == 20
    end
  end

  describe "execute_global_connection_metrics/0" do
    test "emits global connection counts without a tenant tag" do
      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      :ok = Beacon.join(:users, "global-test-tenant", pid)

      TenantGlobal.execute_global_connection_metrics()

      Process.sleep(100)

      assert metric_value("realtime_connections_global_connected") >= 0
      assert metric_value("realtime_connections_global_connected_cluster") >= 0
    end
  end

  defp metric_value(metric, expected_tags \\ nil) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, expected_tags)
  end
end
