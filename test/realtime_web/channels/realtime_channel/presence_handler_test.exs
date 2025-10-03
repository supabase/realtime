defmodule RealtimeWeb.RealtimeChannel.PresenceHandlerTest do
  use Realtime.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog
  import Generators

  alias Phoenix.Socket.Broadcast
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  setup [:initiate_tenant]

  describe "is_private?/1" do
    defmodule TestIsPrivate do
      import RealtimeWeb.RealtimeChannel.PresenceHandler

      def check(socket) when is_private?(socket), do: true
      def check(_socket), do: false
    end

    test "returns true if the socket is a private channel", %{tenant: tenant} do
      socket = socket_fixture(tenant, random_string(), random_string(), private?: true)
      assert TestIsPrivate.check(socket)
    end

    test "returns false if the socket is a public channel", %{tenant: tenant} do
      socket = socket_fixture(tenant, random_string(), random_string(), private?: false)
      refute TestIsPrivate.check(socket)
    end
  end

  describe "can_read_presence?/1" do
    defmodule TestCanReadPresence do
      import RealtimeWeb.RealtimeChannel.PresenceHandler

      def check(socket) when can_read_presence?(socket), do: true
      def check(_socket), do: false
    end

    test "returns true if the socket is a private channel and the presence read policy is true", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{read: true}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: true)
      assert TestCanReadPresence.check(socket)
    end

    test "returns false if the socket is a private channel and the presence read policy is false", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{read: false}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: true)
      refute TestCanReadPresence.check(socket)
    end

    test "returns false if the socket is a public channel ", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{read: true}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: false)
      refute TestCanReadPresence.check(socket)

      policies = %Policies{presence: %PresencePolicies{read: false}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: false)
      refute TestCanReadPresence.check(socket)
    end
  end

  describe "can_write_presence?/1" do
    defmodule TestCanWritePresence do
      import RealtimeWeb.RealtimeChannel.PresenceHandler

      def check(socket) when can_write_presence?(socket), do: true
      def check(_socket), do: false
    end

    test "returns true if the socket is a private channel and the presence write policy is true", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{write: true}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: true)
      assert TestCanWritePresence.check(socket)
    end

    test "returns false if the socket is a private channel and the presence write policy is false", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{write: false}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: true)
      refute TestCanWritePresence.check(socket)
    end

    test "returns false if the socket is a public channel and the presence write does not matter", %{tenant: tenant} do
      policies = %Policies{presence: %PresencePolicies{write: true}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: false)
      refute TestCanWritePresence.check(socket)

      policies = %Policies{presence: %PresencePolicies{write: false}}
      socket = socket_fixture(tenant, random_string(), random_string(), policies: policies, private?: false)
      refute TestCanWritePresence.check(socket)
    end
  end

  describe "handle/3" do
    setup do
      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      :telemetry.attach(
        __MODULE__,
        [:realtime, :tenants, :payload, :size],
        &__MODULE__.handle_telemetry/4,
        pid: self()
      )
    end

    test "with true policy and is private, user can track their presence and changes", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      external_id = tenant.external_id
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}

      socket =
        socket_fixture(tenant, topic, key, policies: policies)

      PresenceHandler.handle(%{"event" => "track", "payload" => %{"A" => "b", "c" => "b"}}, db_conn, socket)
      topic = socket.assigns.tenant_topic

      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 30},
                      %{tenant: ^external_id, message_type: :presence}}
    end

    test "when tracking already existing user, metadata updated", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      external_id = tenant.external_id
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies)

      assert {:ok, socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)

      topic = socket.assigns.tenant_topic
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      payload = %{"event" => "track", "payload" => %{"content" => random_string()}}
      assert {:ok, _socket} = PresenceHandler.handle(payload, db_conn, socket)

      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 6},
                      %{tenant: ^external_id, message_type: :presence}}

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 55},
                      %{tenant: ^external_id, message_type: :presence}}

      refute_receive :_
    end

    test "with false policy and is public, user can track their presence and changes", %{tenant: tenant, topic: topic} do
      external_id = tenant.external_id
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: false, write: false}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false)

      assert {:ok, _socket} = PresenceHandler.handle(%{"event" => "track"}, nil, socket)

      topic = socket.assigns.tenant_topic
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 6},
                      %{tenant: ^external_id, message_type: :presence}}
    end

    test "user can untrack when they want", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies)

      assert {:ok, socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)

      topic = socket.assigns.tenant_topic
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert {:ok, _socket} = PresenceHandler.handle(%{"event" => "untrack"}, db_conn, socket)
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: %{}, leaves: leaves}}
      assert Map.has_key?(leaves, key)
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "only checks write policies once on private channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
        call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
      end)

      reject(&Authorization.get_write_authorizations/3)

      key = random_string()
      socket = socket_fixture(tenant, topic, key)
      topic = socket.assigns.tenant_topic

      for _ <- 1..300, reduce: socket do
        socket ->
          assert {:ok, socket} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     db_conn,
                     socket
                   )

          assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
          socket
      end
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :broken_write_presence]
    test "handle failing rls policy", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
        call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
      end)

      key = random_string()
      socket = socket_fixture(tenant, topic, key)
      topic = socket.assigns.tenant_topic

      log =
        capture_log(fn ->
          assert {:error, :rls_policy_error} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     db_conn,
                     socket
                   )

          refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}, 1000
        end)

      assert log =~ "RlsPolicyError"
    end

    test "does not check write policies once on public channels", %{tenant: tenant, topic: topic} do
      reject(&Authorization.get_write_authorizations/3)

      key = random_string()
      policies = %Policies{broadcast: %BroadcastPolicies{read: false}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false)
      topic = socket.assigns.tenant_topic

      for _ <- 1..300, reduce: socket do
        socket ->
          assert {:ok, socket} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     nil,
                     socket
                   )

          assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
          socket
      end
    end

    test "logs out non recognized events" do
      socket = %Phoenix.Socket{joined: true}

      log =
        capture_log(fn ->
          assert {:error, :unknown_presence_event} = PresenceHandler.handle(%{"event" => "unknown"}, nil, socket)
        end)

      assert log =~ "UnknownPresenceEvent"
    end

    test "socket with presence enabled false will ignore non-track presence events in public channel", %{
      tenant: tenant,
      topic: topic
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false, enabled?: false)

      assert {:ok, _socket} = PresenceHandler.handle(%{"event" => "untrack"}, nil, socket)
      topic = socket.assigns.tenant_topic
      refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}
    end

    test "socket with presence enabled false will ignore non-track presence events in private channel", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false, enabled?: false)

      assert {:ok, _socket} = PresenceHandler.handle(%{"event" => "untrack"}, db_conn, socket)
      topic = socket.assigns.tenant_topic
      refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}
    end

    test "socket with presence disabled will enable presence on track message for public channel", %{
      tenant: tenant,
      topic: topic
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false, enabled?: false)

      refute socket.assigns.presence_enabled?

      assert {:ok, updated_socket} = PresenceHandler.handle(%{"event" => "track"}, nil, socket)

      assert updated_socket.assigns.presence_enabled?
      topic = socket.assigns.tenant_topic
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "socket with presence disabled will enable presence on track message for private channel", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: true, enabled?: false)

      refute socket.assigns.presence_enabled?

      assert {:ok, updated_socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)

      assert updated_socket.assigns.presence_enabled?
      topic = socket.assigns.tenant_topic
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "socket with presence disabled will not enable presence on untrack message", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, enabled?: false)

      refute socket.assigns.presence_enabled?

      assert {:ok, updated_socket} = PresenceHandler.handle(%{"event" => "untrack"}, db_conn, socket)

      refute updated_socket.assigns.presence_enabled?
      topic = socket.assigns.tenant_topic
      refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}
    end

    test "socket with presence disabled will not enable presence on unknown event", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, enabled?: false)

      refute socket.assigns.presence_enabled?

      assert {:error, :unknown_presence_event} = PresenceHandler.handle(%{"event" => "unknown"}, db_conn, socket)
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "rate limit is checked on private channel", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: true)

      log =
        capture_log(fn ->
          for _ <- 1..300, do: PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
          Process.sleep(1100)

          assert {:error, :rate_limit_exceeded} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
        end)

      assert log =~ "PresenceRateLimitReached"
    end

    test "rate limit is checked on public channel", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()
      socket = socket_fixture(tenant, topic, key, private?: false)

      log =
        capture_log(fn ->
          for _ <- 1..300, do: PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
          Process.sleep(1100)

          assert {:error, :rate_limit_exceeded} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
        end)

      assert log =~ "PresenceRateLimitReached"
    end
  end

  describe "sync/1" do
    test "syncs presence state for public channels", %{tenant: tenant, topic: topic} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: false, write: false}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: false)

      assert :ok = PresenceHandler.sync(socket)
      assert_receive {_, :text, msg}
      msg = Jason.decode!(msg)
      assert msg["event"] == "presence_state"
    end

    test "syncs presence state for private channels with read policy true", %{tenant: tenant, topic: topic} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: true)

      assert :ok = PresenceHandler.sync(socket)
      assert_receive {_, :text, msg}
      msg = Jason.decode!(msg)
      assert msg["event"] == "presence_state"
    end

    test "ignores sync for private channels with read policy false", %{tenant: tenant, topic: topic} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: false, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: true)

      assert :ok = PresenceHandler.sync(socket)
      refute_receive {_, :text, _}
    end

    test "ignores sync when presence is disabled", %{tenant: tenant, topic: topic} do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies: policies, private?: true, enabled?: false)

      assert :ok = PresenceHandler.sync(socket)
      refute_receive {_, :text, _}
    end

    test "respects rate limits on public channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()
      socket = socket_fixture(tenant, topic, key, private?: false)

      log =
        capture_log(fn ->
          for _ <- 1..300, do: PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
          Process.sleep(1100)

          assert {:error, :rate_limit_exceeded} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
        end)

      assert log =~ "PresenceRateLimitReached"
    end

    @tag :skip
    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "respects rate limits on private channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()
      socket = socket_fixture(tenant, topic, key, private?: true)

      log =
        capture_log(fn ->
          for _ <- 1..300, do: PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
          Process.sleep(1100)

          assert {:error, :rate_limit_exceeded} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
        end)

      assert log =~ "PresenceRateLimitReached"
    end
  end

  defp initiate_tenant(context) do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)

    topic = random_string()
    if policies = context[:policies], do: create_rls_policies(db_conn, policies, %{topic: topic})

    {:ok, tenant: tenant, db_conn: db_conn, topic: topic}
  end

  defp socket_fixture(tenant, topic, presence_key, opts \\ []) do
    policies =
      Keyword.get(opts, :policies, %Policies{
        broadcast: %BroadcastPolicies{read: true},
        presence: %PresencePolicies{read: true, write: nil}
      })

    private? = Keyword.get(opts, :private?, true)
    enabled? = Keyword.get(opts, :enabled?, true)
    log_level = Keyword.get(opts, :log_level, :error)

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

    tenant_topic = Tenants.tenant_topic(tenant.external_id, topic)
    Endpoint.subscribe(tenant_topic)

    rate = Tenants.presence_events_per_second_rate(tenant)

    RateCounter.new(rate)

    %Phoenix.Socket{
      joined: true,
      topic: "realtime:#{topic}",
      transport_pid: self(),
      serializer: Phoenix.Socket.V1.JSONSerializer,
      assigns: %{
        tenant_topic: tenant_topic,
        self_broadcast: true,
        policies: policies,
        authorization_context: authorization_context,
        presence_rate_counter: rate,
        private?: private?,
        presence_key: presence_key,
        presence_enabled?: enabled?,
        log_level: log_level,
        channel_name: topic,
        tenant: tenant.external_id
      }
    }
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {:telemetry, event, measures, metadata})
end
