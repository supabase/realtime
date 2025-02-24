defmodule RealtimeWeb.RealtimeChannel.BroadcastHandlerTest do
  # async: false due to the usage of mocks
  use Realtime.DataCase, async: false

  import Generators
  import Mock

  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RealtimeChannel.BroadcastHandler

  setup [:initiate_tenant]

  describe "call/2" do
    test "with write true policy, user is able to send message", %{topic: topic, tenant: tenant, db_conn: db_conn} do
      socket = socket_fixture(tenant, topic, db_conn, %Policies{broadcast: %BroadcastPolicies{write: true}})

      for _ <- 1..100, reduce: socket do
        socket ->
          {:reply, :ok, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1200)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg > 0
    end

    test "with write false policy, user is not able to send message", %{topic: topic, tenant: tenant, db_conn: db_conn} do
      socket = socket_fixture(tenant, topic, db_conn, %Policies{broadcast: %BroadcastPolicies{write: false}})

      for _ <- 1..100, reduce: socket do
        socket ->
          {:noreply, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1200)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg == 0.0
    end

    @tag policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]
    test "with nil policy but valid user, is able to send message", %{
      topic: topic,
      tenant: tenant,
      db_conn: db_conn
    } do
      socket = socket_fixture(tenant, topic, db_conn)

      for _ <- 1..100, reduce: socket do
        socket ->
          {:reply, :ok, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1000)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg > 0.0
    end

    test "with nil policy and invalid user, is not able to send message", %{
      topic: topic,
      tenant: tenant,
      db_conn: db_conn
    } do
      socket = socket_fixture(tenant, topic, db_conn)

      for _ <- 1..100, reduce: socket do
        socket ->
          {:noreply, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1200)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg == 0.0
    end

    @tag policies: [:authenticated_read_broadcast, :authenticated_write_broadcast]

    test "validation only runs once on nil and valid policies", %{
      topic: topic,
      tenant: tenant,
      db_conn: db_conn
    } do
      socket = socket_fixture(tenant, topic, db_conn)

      with_mock Authorization, [:passthrough], [] do
        for _ <- 1..100, reduce: socket do
          socket ->
            {:reply, :ok, socket} = BroadcastHandler.handle(%{}, socket)
            topic = "realtime:#{topic}"
            assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
            socket
        end

        assert_called_exactly(Authorization.get_write_authorizations(:_, :_, :_), 1)
      end
    end

    test "validation only runs once on nil and blocking policies", %{
      topic: topic,
      tenant: tenant,
      db_conn: db_conn
    } do
      socket = socket_fixture(tenant, topic, db_conn)

      with_mock Authorization, [:passthrough], [] do
        for _ <- 1..100, reduce: socket do
          socket ->
            {:noreply, socket} = BroadcastHandler.handle(%{}, socket)
            topic = "realtime:#{topic}"
            refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
            socket
        end

        assert_called_exactly(Authorization.get_write_authorizations(:_, :_, :_), 1)
      end
    end

    test "no ack still sends message", %{
      topic: topic,
      tenant: tenant,
      db_conn: db_conn
    } do
      socket = socket_fixture(tenant, topic, db_conn, %Policies{broadcast: %BroadcastPolicies{write: true}}, false)

      for _ <- 1..100, reduce: socket do
        socket ->
          {:noreply, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end
    end

    test "public channels are able to send messages", %{topic: topic, tenant: tenant, db_conn: db_conn} do
      socket = socket_fixture(tenant, topic, db_conn, nil, false, false)

      for _ <- 1..100, reduce: socket do
        socket ->
          {:noreply, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1100)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg > 0.0
    end

    test "public channels are able to send messages and ack", %{topic: topic, tenant: tenant, db_conn: db_conn} do
      socket = socket_fixture(tenant, topic, db_conn, nil, true, false)

      for _ <- 1..100, reduce: socket do
        socket ->
          {:reply, :ok, socket} = BroadcastHandler.handle(%{}, socket)
          topic = "realtime:#{topic}"
          assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "broadcast", payload: %{}}
          socket
      end

      Process.sleep(1000)
      {:ok, %{avg: avg}} = RateCounter.get(Tenants.events_per_second_key(tenant))
      assert avg > 0.0
    end
  end

  defp initiate_tenant(context) do
    start_supervised(Realtime.GenCounter.DynamicSupervisor)
    start_supervised(Realtime.RateCounter.DynamicSupervisor)
    start_supervised(CurrentTime.Mock)

    tenant = Containers.checkout_tenant(true)
    RateCounter.stop(tenant.external_id)
    GenCounter.stop(tenant.external_id)
    RateCounter.new(tenant.external_id)
    GenCounter.new(tenant.external_id)

    on_exit(fn ->
      Containers.checkin_tenant(tenant)
    end)

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    Process.sleep(500)

    topic = random_string()
    Endpoint.subscribe("realtime:#{topic}")
    if policies = context[:policies], do: create_rls_policies(db_conn, policies, %{topic: topic})

    {:ok, tenant: tenant, db_conn: db_conn, topic: topic}
  end

  defp socket_fixture(
         tenant,
         topic,
         db_conn,
         policies \\ %Policies{broadcast: %BroadcastPolicies{write: nil, read: true}},
         ack_broadcast \\ true,
         private? \\ true
       ) do
    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    key = Tenants.events_per_second_key(tenant)
    GenCounter.new(key)
    RateCounter.new(key)
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
        db_conn: db_conn
      }
    }
  end
end
