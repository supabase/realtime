defmodule RealtimeWeb.RealtimeChannel.PresenceHandlerTest do
  # async: false due to the usage of mocks
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog
  import Generators
  import Mock

  alias Phoenix.Socket.Broadcast
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.Joken.CurrentTime
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  setup [:initiate_tenant]

  describe "handle/2" do
    test "with true policy and is private, user can track their presence and changes", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, db_conn, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "when tracking already existing user, metadata updated", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, db_conn, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      assert {:reply, :ok, socket} = PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert {:reply, :ok, _socket} =
               PresenceHandler.handle(%{"event" => "track", "payload" => %{"content" => random_string()}}, socket)

      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
      refute_receive :_
    end

    test "with false policy and is public, user can track their presence and changes", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()

      socket =
        socket_fixture(
          tenant,
          topic,
          db_conn,
          key,
          %Policies{presence: %PresencePolicies{read: false, write: false}},
          false
        )

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "user can untrack when they want", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, db_conn, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      assert {:reply, :ok, socket} = PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "untrack"}, socket)
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: %{}, leaves: leaves}}
      assert Map.has_key?(leaves, key)
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "only checks write policies once on private channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      with_mock Authorization, [:passthrough], [] do
        key = random_string()
        socket = socket_fixture(tenant, topic, db_conn, key)
        topic = "realtime:#{topic}"

        for _ <- 1..100, reduce: socket do
          socket ->
            assert {:reply, :ok, socket} =
                     PresenceHandler.handle(
                       %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                       socket
                     )

            assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
            socket
        end

        assert_called_exactly(Authorization.get_write_authorizations(:_, :_, :_), 1)
      end
    end

    test "does not check write policies once on public channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      with_mock Authorization, [:passthrough], [] do
        key = random_string()

        socket =
          socket_fixture(tenant, topic, db_conn, key, %Policies{broadcast: %BroadcastPolicies{read: false}}, false)

        topic = "realtime:#{topic}"

        for _ <- 1..100, reduce: socket do
          socket ->
            assert {:reply, :ok, socket} =
                     PresenceHandler.handle(
                       %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                       socket
                     )

            assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
            socket
        end

        assert_not_called(Authorization.get_write_authorizations(:_, :_, :_))
      end
    end

    test "logs out non recognized events" do
      with_mock Authorization, [:passthrough], [] do
        socket = %Phoenix.Socket{joined: true}

        log =
          capture_log(fn ->
            assert {:reply, :error, %Phoenix.Socket{}} = PresenceHandler.handle(%{"event" => "unknown"}, socket)
          end)

        assert log =~ "UnknownPresenceEvent"
      end
    end
  end

  defp initiate_tenant(context) do
    start_supervised(Realtime.GenCounter.DynamicSupervisor)
    start_supervised(Realtime.RateCounter.DynamicSupervisor)
    start_supervised(CurrentTime.Mock)

    tenant = Containers.checkout_tenant(run_migrations: true)

    RateCounter.stop(tenant.external_id)
    GenCounter.stop(tenant.external_id)
    RateCounter.new(tenant.external_id)
    GenCounter.new(tenant.external_id)

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)

    topic = random_string()
    Endpoint.subscribe("realtime:#{topic}")
    if policies = context[:policies], do: create_rls_policies(db_conn, policies, %{topic: topic})

    {:ok, tenant: tenant, db_conn: db_conn, topic: topic}
  end

  defp socket_fixture(
         tenant,
         topic,
         db_conn,
         presence_key,
         policies \\ %Policies{
           broadcast: %BroadcastPolicies{read: true},
           presence: %PresencePolicies{read: true, write: nil}
         },
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
    GenCounter.new(key)
    RateCounter.new(key)
    {:ok, rate_counter} = RateCounter.get(key)

    tenant_topic = "realtime:#{topic}"
    self_broadcast = true

    %Phoenix.Socket{
      joined: true,
      topic: tenant_topic,
      assigns: %{
        tenant_topic: tenant_topic,
        self_broadcast: self_broadcast,
        policies: policies,
        authorization_context: authorization_context,
        rate_counter: rate_counter,
        private?: private?,
        db_conn: db_conn,
        presence_key: presence_key
      }
    }
  end
end
