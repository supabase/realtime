defmodule Realtime.Tenants.SingleBroadcastTest do
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  alias Realtime.Database
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.SingleBroadcast
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect

  alias RealtimeWeb.TenantBroadcaster
  alias RealtimeWeb.Socket.UserBroadcast

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Realtime.Tenants.Cache.update_cache(tenant)
    {:ok, tenant: tenant}
  end

  describe "JSON public message broadcasting" do
    test "broadcasts JSON public message successfully", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()
      tenant_topic = Tenants.tenant_topic(tenant.external_id, topic)
      event = "test-event"
      payload = %{"text" => "hello", "user" => "alice"}

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, broadcast, _, _ ->
        assert %UserBroadcast{
                 topic: ^tenant_topic,
                 user_event: ^event,
                 user_payload: json,
                 user_payload_encoding: :json,
                 metadata: nil
               } = broadcast

        assert IO.iodata_to_binary(json) == Jason.encode!(payload)

        :ok
      end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, event, false, payload, :json)
    end

    test "public messages do not have private prefix in topic", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, tenant_topic, _, _, _ ->
        refute String.contains?(tenant_topic, "-private")
        :ok
      end)

      assert :ok =
               SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, %{"data" => "test"}, :json)
    end

    test "JSON payload can be empty map", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, %{}, :json)
    end
  end

  describe "Binary public message broadcasting" do
    test "broadcasts binary message successfully", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()
      tenant_topic = Tenants.tenant_topic(tenant.external_id, topic)
      event = "binary-event"
      binary = <<1, 2, 3, 4, 5>>

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, broadcast, _, _ ->
        assert %UserBroadcast{
                 topic: ^tenant_topic,
                 user_event: ^event,
                 user_payload: ^binary,
                 user_payload_encoding: :binary,
                 metadata: nil
               } = broadcast

        :ok
      end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, event, false, binary, :binary)
    end

    test "binary payload can be empty", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, <<>>, :binary)
    end

    test "handles large binary payloads within limit", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()
      # Create binary well under the limit to account for erlang term overhead
      # The max is in KB (1000 bytes per KB), plus 500 byte padding
      binary = :crypto.strong_rand_bytes(tenant.max_payload_size_in_kb * 1000 - 100)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, binary, :binary)
    end
  end

  describe "JSON private message authorization" do
    test "broadcasts private JSON message with valid authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"
      payload = %{"secret" => "data"}

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      broadcast_events_key = Tenants.events_per_second_key(tenant)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _ ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, tenant_topic, _, _, _ ->
        assert String.contains?(tenant_topic, "-private")
        :ok
      end)

      assert :ok = SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, payload, :json)
    end

    test "skips private JSON message without authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "anon"

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      expect(Authorization, :get_write_authorizations, fn _, _ ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :forbidden, "Unauthorized"} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, %{"data" => "test"}, :json)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "Binary private message authorization" do
    test "broadcasts private binary message with valid authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"
      binary = <<255, 254, 253>>

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      broadcast_events_key = Tenants.events_per_second_key(tenant)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _ ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, tenant_topic, broadcast, _, _ ->
        assert String.contains?(tenant_topic, "-private")

        assert %UserBroadcast{
                 user_payload: ^binary,
                 user_payload_encoding: :binary
               } = broadcast

        :ok
      end)

      assert :ok = SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, binary, :binary)
    end

    test "skips private binary message without authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "anon"

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      expect(Authorization, :get_write_authorizations, fn _, _ ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :forbidden, "Unauthorized"} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, <<1, 2, 3>>, :binary)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "message validation" do
    test "returns changeset error when topic is empty", %{tenant: tenant} do
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, "", "event", false, %{"data" => "test"}, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when event is empty", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "", false, %{"data" => "test"}, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when JSON payload is nil", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, nil, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when binary payload is nil", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, nil, :binary)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end
  end

  describe "rate limiting" do
    test "rejects broadcast when rate limit is exceeded", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      topic = random_string()

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}} end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, %{"data" => "test"}, :json)
      assert {:error, :too_many_requests, "You have exceeded your rate limit"} = result
    end

    test "allows broadcast at rate limit boundary", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      current_rate = tenant.max_events_per_second - 1

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: current_rate}}
      end)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok =
               SingleBroadcast.broadcast(
                 %Authorization{},
                 tenant,
                 random_string(),
                 "event",
                 false,
                 %{"data" => "test"},
                 :json
               )
    end

    test "rejects JSON payload when size exceeds tenant limit", %{tenant: tenant} do
      topic = random_string()
      large_payload = %{"data" => random_string(tenant.max_payload_size_in_kb * 1000 + 1)}

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, large_payload, :json)

      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} = result
      assert {:payload, {"Payload size exceeds tenant limit", []}} in errors
    end

    test "rejects binary payload when size exceeds tenant limit", %{tenant: tenant} do
      topic = random_string()
      large_binary = :crypto.strong_rand_bytes(tenant.max_payload_size_in_kb * 1024 + 1)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", false, large_binary, :binary)

      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} = result
      assert {:payload, {"Payload size exceeds tenant limit", []}} in errors
    end
  end

  describe "error handling" do
    test "database connection errors for private messages returns error", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: 0}} end)

      expect(Connect, :lookup_or_start_connection, fn _ -> {:error, :tenant_database_unavailable} end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :unprocessable_entity, "Tenant database unavailable"} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, %{"data" => "test"}, :json)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "integration with RLS policies" do
    setup %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      %{db_conn: db_conn}
    end

    test "broadcasts private JSON message when RLS policy allows", %{tenant: tenant, db_conn: db_conn} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      create_rls_policies(db_conn, [:authenticated_write_broadcast], %{topic: topic})

      auth_params =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          headers: [{"header-1", "value-1"}],
          claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
          role: role,
          sub: sub
        })

      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      broadcast_events_key = Tenants.events_per_second_key(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn
        ^events_per_second_rate -> {:ok, %RateCounter{avg: 0}}
        _ -> {:ok, %RateCounter{avg: 0}}
      end)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)

      expect(Authorization, :get_write_authorizations, fn _, _ ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", true, %{"secret" => "data"}, :json)
    end
  end
end
