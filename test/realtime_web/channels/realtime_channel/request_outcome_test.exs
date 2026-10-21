defmodule RealtimeWeb.RealtimeChannel.RequestOutcomeTest do
  # The broadcast outcomes RealtimeChannel.handle_in/3 records for the client request ingress SLI.
  use Realtime.DataCase, async: true

  use Mimic

  setup :set_mimic_from_context

  alias Ecto.UUID
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.RealtimeChannel
  alias RealtimeWeb.RequestMetrics

  @payload %{"event" => "test", "payload" => %{"a" => "b"}}

  # Telemetry handlers are global and run in the emitting process, so forward only this test's events.
  def forward(_event, _measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:outcome, metadata})
  end

  setup do
    test_pid = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      RequestMetrics.event(),
      &__MODULE__.forward/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  setup context do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    Realtime.Tenants.Cache.update_cache(tenant)
    RateCounter.new(Tenants.events_per_second_rate(tenant), tick: 100)

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)

    Map.merge(context, %{tenant: tenant, db_conn: db_conn, topic: random_string()})
  end

  describe "private broadcast" do
    test "a permitted broadcast is a success", %{tenant: tenant, topic: topic} do
      socket = socket_fixture(tenant, topic, policies: %Policies{broadcast: %BroadcastPolicies{write: true}})

      assert {:reply, :ok, _} = RealtimeChannel.handle_in("broadcast", @payload, socket)

      assert_receive {:outcome, %{request: :broadcast, transport: :ws, outcome: :success, reason: :none}}
      refute_receive {:outcome, _}
    end

    test "the client still gets the same reply", %{tenant: tenant, topic: topic} do
      socket = socket_fixture(tenant, topic, policies: %Policies{broadcast: %BroadcastPolicies{write: false}})

      assert {:reply, {:error, %{error: :unauthorized}}, returned} =
               RealtimeChannel.handle_in("broadcast", @payload, socket)

      assert_receive {:outcome, %{outcome: :rejected}}
      assert returned.assigns == socket.assigns
    end

    test "a policy deny is rejected, with or without ack", %{tenant: tenant, topic: topic} do
      for ack <- [true, false] do
        socket =
          socket_fixture(tenant, topic,
            ack_broadcast: ack,
            policies: %Policies{broadcast: %BroadcastPolicies{write: false}}
          )

        RealtimeChannel.handle_in("broadcast", @payload, socket)

        assert_receive {:outcome, %{outcome: :rejected, reason: :unauthorized}}
      end
    end

    test "an oversized payload is rejected, with or without ack", %{tenant: tenant, topic: topic} do
      payload = oversized_payload(tenant)

      for ack <- [true, false] do
        socket =
          socket_fixture(tenant, topic,
            ack_broadcast: ack,
            policies: %Policies{broadcast: %BroadcastPolicies{write: true}}
          )

        RealtimeChannel.handle_in("broadcast", payload, socket)

        assert_receive {:outcome, %{outcome: :rejected, reason: :payload_size_exceeded}}
      end
    end

    test "unacked broadcasts are classified even though the reply is a bare noreply", %{tenant: tenant, topic: topic} do
      stub(Authorization, :get_write_authorizations, fn _, _, _, _ -> {:error, :query_canceled, "timeout"} end)
      socket = socket_fixture(tenant, topic, ack_broadcast: false, policies: nil)

      assert {:noreply, _} = RealtimeChannel.handle_in("broadcast", @payload, socket)

      assert_receive {:outcome, %{outcome: :upstream_failure, reason: :query_canceled}}
    end

    test "authorization errors map to the proposal's table", %{tenant: tenant, topic: topic} do
      cases = [
        {{:error, :rls_policy_error, "raised"}, :upstream_failure, :rls_policy_error},
        {{:error, :query_canceled, "timeout"}, :upstream_failure, :query_canceled},
        {{:error, :missing_partition}, :internal_failure, :missing_partition},
        {{:error, :tenant_database_unavailable}, :upstream_failure, :unable_to_connect_to_project},
        {{:error, :increase_connection_pool}, :upstream_failure, :increase_connection_pool},
        {{:error, :something_unexpected}, :internal_failure, :unable_to_set_policies}
      ]

      for {error, outcome, reason} <- cases do
        stub(Authorization, :get_write_authorizations, fn _, _, _, _ -> error end)
        socket = socket_fixture(tenant, topic, policies: nil)

        RealtimeChannel.handle_in("broadcast", @payload, socket)

        assert_receive {:outcome, %{outcome: ^outcome, reason: ^reason}}, 500, "for #{inspect(error)}"
      end
    end

    test "tenant database connection errors are upstream failures", %{tenant: tenant, topic: topic} do
      cases = [
        {{:error, :tenant_db_too_many_connections}, :upstream_failure, :database_lack_of_connections},
        {{:error, :connect_rate_limit_reached}, :upstream_failure, :database_connection_rate_limit_reached},
        {{:error, :initializing}, :upstream_failure, :initializing_project_connection},
        {{:error, :rpc_error, "badrpc"}, :internal_failure, :unable_to_handle_broadcast}
      ]

      for {error, outcome, reason} <- cases do
        stub(Connect, :lookup_or_start_connection, fn _ -> error end)
        socket = socket_fixture(tenant, topic)

        RealtimeChannel.handle_in("broadcast", @payload, socket)

        assert_receive {:outcome, %{outcome: ^outcome, reason: ^reason}}, 500, "for #{inspect(error)}"
      end
    end

    test "a crash is counted as an internal failure and still raised", %{tenant: tenant, topic: topic} do
      stub(Authorization, :get_write_authorizations, fn _, _, _, _ -> raise "boom" end)
      socket = socket_fixture(tenant, topic, policies: nil)

      assert_raise RuntimeError, "boom", fn -> RealtimeChannel.handle_in("broadcast", @payload, socket) end

      assert_receive {:outcome, %{request: :broadcast, outcome: :internal_failure, reason: :error}}
      refute_receive {:outcome, _}
    end
  end

  describe "public broadcast" do
    test "is a success", %{tenant: tenant, topic: topic} do
      socket = socket_fixture(tenant, topic, private?: false)

      assert {:reply, :ok, _} = RealtimeChannel.handle_in("broadcast", @payload, socket)

      assert_receive {:outcome, %{outcome: :success, reason: :none}}
    end

    test "an oversized payload is rejected", %{tenant: tenant, topic: topic} do
      socket = socket_fixture(tenant, topic, private?: false)

      RealtimeChannel.handle_in("broadcast", oversized_payload(tenant), socket)

      assert_receive {:outcome, %{outcome: :rejected, reason: :payload_size_exceeded}}
    end
  end

  test "requests other than broadcast are not tracked yet", %{tenant: tenant, topic: topic} do
    socket = socket_fixture(tenant, topic)

    assert {:noreply, _} = RealtimeChannel.handle_in("unknown_type", %{}, socket)

    refute_receive {:outcome, _}
  end

  defp oversized_payload(tenant) do
    %{"event" => "test", "payload" => %{"data" => String.duplicate("a", (tenant.max_payload_size_in_kb + 1) * 1000)}}
  end

  defp socket_fixture(tenant, topic, opts \\ []) do
    policies = Keyword.get(opts, :policies, %Policies{broadcast: %BroadcastPolicies{write: nil, read: true}})
    ack_broadcast = Keyword.get(opts, :ack_broadcast, true)
    private? = Keyword.get(opts, :private?, true)

    claims = %{sub: UUID.generate(), role: "authenticated", exp: Joken.current_time() + 1_000}
    jwt = Joken.generate_and_sign!(%{}, claims, Joken.Signer.create("HS256", "secret"))

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role,
        sub: claims.sub
      })

    %Phoenix.Socket{
      assigns: %{
        tenant_topic: "realtime:#{topic}",
        ack_broadcast: ack_broadcast,
        self_broadcast: true,
        policies: policies,
        authorization_context: authorization_context,
        private?: private?,
        tenant: tenant.external_id
      }
    }
  end
end
