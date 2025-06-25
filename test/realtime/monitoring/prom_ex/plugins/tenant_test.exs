defmodule Realtime.PromEx.Plugins.TenantTest do
  alias Realtime.Tenants.Authorization.Policies
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.Tenant
  alias Realtime.Rpc
  alias Realtime.UsersCounter
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_phoenix

    @impl true
    def plugins, do: [{Tenant, poll_rate: 50}]
  end

  def handle_telemetry(event, metadata, content, pid: pid), do: send(pid, {event, metadata, content})

  @aux_mod (quote do
              defmodule FakeUserCounter do
                def fake_add(external_id) do
                  :ok = UsersCounter.add(spawn(fn -> Process.sleep(2000) end), external_id)
                end

                def fake_db_event(external_id) do
                  external_id |> Realtime.Tenants.db_events_per_second_key() |> Realtime.GenCounter.new()

                  external_id
                  |> Realtime.Tenants.db_events_per_second_key()
                  |> Realtime.RateCounter.new(
                    telemetry: %{
                      event_name: [:channel, :db_events],
                      measurements: %{},
                      metadata: %{tenant: external_id}
                    }
                  )

                  external_id
                  |> Realtime.Tenants.db_events_per_second_key()
                  |> Realtime.GenCounter.add()
                end

                def fake_event(external_id) do
                  external_id |> Realtime.Tenants.events_per_second_key() |> Realtime.GenCounter.new()

                  external_id
                  |> Realtime.Tenants.events_per_second_key()
                  |> Realtime.RateCounter.new(
                    telemetry: %{
                      event_name: [:channel, :events],
                      measurements: %{},
                      metadata: %{tenant: external_id}
                    }
                  )

                  external_id
                  |> Realtime.Tenants.events_per_second_key()
                  |> Realtime.GenCounter.add()
                end

                def fake_presence_event(external_id) do
                  external_id |> Realtime.Tenants.presence_events_per_second_key() |> Realtime.GenCounter.new()

                  external_id
                  |> Realtime.Tenants.presence_events_per_second_key()
                  |> Realtime.RateCounter.new(
                    telemetry: %{
                      event_name: [:channel, :presence_events],
                      measurements: %{},
                      metadata: %{tenant: external_id}
                    }
                  )

                  external_id
                  |> Realtime.Tenants.presence_events_per_second_key()
                  |> Realtime.GenCounter.add()
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  describe "execute_tenant_metrics/0" do
    setup do
      tenant = Containers.checkout_tenant()
      :telemetry.attach(__MODULE__, [:realtime, :connections], &__MODULE__.handle_telemetry/4, pid: self())

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      {:ok, node} = Clustered.start(@aux_mod)
      %{tenant: tenant, node: node}
    end

    test "returns a list of tenant metrics and handles bad tenant ids", %{
      tenant: %{external_id: external_id},
      node: node
    } do
      UsersCounter.add(self(), external_id)
      # Add bad tenant id
      UsersCounter.add(self(), random_string())

      _ = Rpc.call(node, FakeUserCounter, :fake_add, [external_id])
      Process.sleep(500)
      Tenant.execute_tenant_metrics()

      assert_receive {[:realtime, :connections], %{connected: 1, limit: 200, connected_cluster: 2},
                      %{tenant: ^external_id}}

      refute_receive :_
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

      start_supervised!(MetricsTest)

      %{authorization_context: authorization_context, db_conn: db_conn, tenant: tenant}
    end

    test "event exists after counter added", %{tenant: %{external_id: external_id}} do
      pattern =
        ~r/realtime_channel_events{tenant="#{external_id}"}\s(?<number>\d+)/

      metric_value = metric_value(pattern)
      FakeUserCounter.fake_event(external_id)

      Process.sleep(100)
      assert metric_value(pattern) == metric_value + 1
    end

    test "db_event exists after counter added", %{tenant: %{external_id: external_id}} do
      pattern =
        ~r/realtime_channel_db_events{tenant="#{external_id}"}\s(?<number>\d+)/

      metric_value = metric_value(pattern)
      FakeUserCounter.fake_db_event(external_id)
      Process.sleep(100)
      assert metric_value(pattern) == metric_value + 1
    end

    test "presence_event exists after counter added", %{tenant: %{external_id: external_id}} do
      pattern =
        ~r/realtime_channel_presence_events{tenant="#{external_id}"}\s(?<number>\d+)/

      metric_value = metric_value(pattern)
      FakeUserCounter.fake_presence_event(external_id)
      Process.sleep(100)
      assert metric_value(pattern) == metric_value + 1
    end

    test "metric read_authorization_check exists after check", context do
      pattern =
        ~r/realtime_tenants_read_authorization_check_count{tenant="#{context.tenant.external_id}"}\s(?<number>\d+)/

      metric_value = metric_value(pattern)

      {:ok, _} =
        Authorization.get_read_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      Process.sleep(200)

      assert metric_value(pattern) == metric_value + 1

      bucket_pattern =
        ~r/realtime_tenants_read_authorization_check_bucket{tenant="#{context.tenant.external_id}",le="250"}\s(?<number>\d+)/

      assert metric_value(bucket_pattern) > 0
    end

    test "metric write_authorization_check exists after check", context do
      pattern =
        ~r/realtime_tenants_write_authorization_check_count{tenant="#{context.tenant.external_id}"}\s(?<number>\d+)/

      metric_value = metric_value(pattern)

      {:ok, _} =
        Authorization.get_write_authorizations(
          %Policies{},
          context.db_conn,
          context.authorization_context
        )

      # Wait enough time for the poll rate to be triggered at least once
      Process.sleep(200)

      assert metric_value(pattern) == metric_value + 1

      bucket_pattern =
        ~r/realtime_tenants_write_authorization_check_bucket{tenant="#{context.tenant.external_id}",le="250"}\s(?<number>\d+)/

      assert metric_value(bucket_pattern) > 0
    end
  end

  defp metric_value(pattern) do
    PromEx.get_metrics(MetricsTest)
    |> String.split("\n", trim: true)
    |> Enum.find_value(
      "0",
      fn item ->
        case Regex.run(pattern, item, capture: ["number"]) do
          [number] -> number
          _ -> false
        end
      end
    )
    |> String.to_integer()
  end
end
