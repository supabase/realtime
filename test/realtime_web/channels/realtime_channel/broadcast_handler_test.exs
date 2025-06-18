defmodule RealtimeWeb.RealtimeChannel.BroadcastHandlerTest do
  use Realtime.DataCase, async: true
  use Mimic

  import Generators
  import ExUnit.CaptureLog

  alias Realtime.RateCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.RealtimeChannel.BroadcastHandler

  setup [:initiate_tenant]

  for adapter <- [:phoenix, :gen_rpc] do
    describe "handle/3 #{adapter}" do
      @describetag adapter: adapter

      test "with write true policy, user is able to send message", %{topic: topic, tenant: tenant, db_conn: db_conn} do
        socket = socket_fixture(tenant, topic, %Policies{broadcast: %BroadcastPolicies{write: true}})

        for _ <- 1..100, reduce: socket do
          socket ->
            {:reply, :ok, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(1200)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg > 0
      end

      test "with write false policy, user is not able to send message", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic, %Policies{broadcast: %BroadcastPolicies{write: false}})

        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(1200)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          refute_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg == 0.0
      end

      @tag policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
      test "with nil policy but valid user, is able to send message", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:reply, :ok, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(1200)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg > 0.0
      end

      test "with nil policy and invalid user, is not able to send message", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(1200)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          refute_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg == 0.0
      end

      @tag policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
      test "validation only runs once on nil and valid policies", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic)

        expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
          call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
        end)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:reply, :ok, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(100)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end
      end

      test "validation only runs once on nil and blocking policies", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic)

        expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
          call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
        end)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(100)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          refute_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end
      end

      test "no ack still sends message", %{
        topic: topic,
        tenant: tenant,
        db_conn: db_conn
      } do
        socket = socket_fixture(tenant, topic, %Policies{broadcast: %BroadcastPolicies{write: true}}, false)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(100)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end
      end

      test "public channels are able to send messages", %{topic: topic, tenant: tenant, db_conn: db_conn} do
        socket = socket_fixture(tenant, topic, nil, false, false)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        Process.sleep(1200)

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg > 0.0
      end

      test "public channels are able to send messages and ack", %{topic: topic, tenant: tenant, db_conn: db_conn} do
        socket = socket_fixture(tenant, topic, nil, true, false)

        for _ <- 1..100, reduce: socket do
          socket ->
            {:reply, :ok, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
            socket
        end

        for _ <- 1..100 do
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
        end

        Process.sleep(1200)
        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg > 0.0
      end

      @tag policies: [:broken_write_presence]
      test "handle failing rls policy", %{topic: topic, tenant: tenant, db_conn: db_conn} do
        socket = socket_fixture(tenant, topic)

        log =
          capture_log(fn ->
            for _ <- 1..100, reduce: socket do
              socket ->
                {:noreply, socket} = BroadcastHandler.handle(%{}, db_conn, socket)
                socket
            end

            Process.sleep(1200)

            for _ <- 1..100 do
              topic = "realtime:#{topic}"
              refute_received %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
            end
          end)

        assert log =~ "RlsPolicyError"

        {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
        assert avg == 0.0
      end
    end
  end

  defp initiate_tenant(context) do
    start_supervised(Realtime.GenCounter.DynamicSupervisor)
    start_supervised(Realtime.RateCounter.DynamicSupervisor)

    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, tenant} = Realtime.Api.update_tenant(tenant, %{broadcast_adapter: context.adapter})

    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)

    topic = random_string()
    Endpoint.subscribe("realtime:#{topic}")
    if policies = context[:policies], do: create_rls_policies(db_conn, policies, %{topic: topic})

    %{tenant: tenant, topic: topic, db_conn: db_conn}
  end

  defp socket_fixture(
         tenant,
         topic,
         policies \\ %Policies{broadcast: %BroadcastPolicies{write: nil, read: true}},
         ack_broadcast \\ true,
         private? \\ true
       ) do
    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")
    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    key = Tenants.events_per_second_key(tenant)
    {:ok, rate_counter} = RateCounter.get(key)

    tenant_topic = "realtime:#{topic}"
    self_broadcast = true

    %Phoenix.Socket{
      assigns: %{
        tenant_topic: tenant_topic,
        ack_broadcast: ack_broadcast,
        self_broadcast: self_broadcast,
        policies: policies,
        authorization_context: authorization_context,
        rate_counter: rate_counter,
        private?: private?,
        tenant: tenant.external_id
      }
    }
  end
end
