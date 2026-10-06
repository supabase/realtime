defmodule Realtime.Tenants.SingleBroadcastTest do
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Realtime.FeatureFlags
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.SingleBroadcast
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Repo

  alias RealtimeWeb.TenantBroadcaster
  alias RealtimeWeb.Socket.UserBroadcast

  setup_all do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
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

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, event, payload, :json)
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
               SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", %{"data" => "test"}, :json)
    end

    test "JSON payload can be empty map", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", %{}, :json)
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

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, event, binary, :binary)
    end

    test "binary payload can be empty", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", <<>>, :binary)
    end

    test "handles large binary payloads within limit", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()
      # Create binary well under the limit to account for erlang term overhead
      # The max is in KB (1000 bytes per KB), plus 500 byte padding
      binary = :crypto.strong_rand_bytes(tenant.max_payload_size_in_kb * 1000 - 100)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", binary, :binary)
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

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, tenant_topic, _, _, _ ->
        assert String.contains?(tenant_topic, "-private")
        :ok
      end)

      assert :ok = SingleBroadcast.broadcast(auth_params, tenant, topic, "event", payload, :json, private: true)
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

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :forbidden, "Unauthorized"} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"data" => "test"}, :json, private: true)

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

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
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

      assert :ok = SingleBroadcast.broadcast(auth_params, tenant, topic, "event", binary, :binary, private: true)
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

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :forbidden, "Unauthorized"} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", <<1, 2, 3>>, :binary, private: true)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "message validation" do
    test "returns changeset error when topic is empty", %{tenant: tenant} do
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, "", "event", %{"data" => "test"}, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when event is empty", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "", %{"data" => "test"}, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when JSON payload is nil", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", nil, :json)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when binary payload is nil", %{tenant: tenant} do
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", nil, :binary)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end
  end

  describe "suspended tenant" do
    test "does not broadcast when tenant is suspended", %{tenant: tenant} do
      tenant = %{tenant | suspend: true}
      topic = random_string()
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", %{"data" => "test"}, :json)
      assert {:error, :forbidden, "Tenant is suspended"} = result
      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
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

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", %{"data" => "test"}, :json)
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
                 %{"data" => "test"},
                 :json
               )
    end

    test "rejects JSON payload when size exceeds tenant limit", %{tenant: tenant} do
      topic = random_string()
      large_payload = %{"data" => random_string(tenant.max_payload_size_in_kb * 1000 + 1)}

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", large_payload, :json)

      assert {:error, %Ecto.Changeset{valid?: false, errors: errors}} = result
      assert {:payload, {"Payload size exceeds tenant limit", []}} in errors
    end

    test "rejects binary payload when size exceeds tenant limit", %{tenant: tenant} do
      topic = random_string()
      large_binary = :crypto.strong_rand_bytes(tenant.max_payload_size_in_kb * 1024 + 1)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = SingleBroadcast.broadcast(%Authorization{}, tenant, topic, "event", large_binary, :binary)

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
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"data" => "test"}, :json, private: true)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "ingress telemetry" do
    setup %{tenant: tenant} do
      attach_ingress_handler()

      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: 0}} end)

      stub(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      %{auth_params: auth_params_fixture(tenant)}
    end

    test "public broadcast that is sent records :none", %{tenant: tenant} do
      assert :ok = SingleBroadcast.broadcast(%Authorization{}, tenant, random_string(), "event", %{"a" => "b"}, :json)

      assert_ingress(:none, :ok)
    end

    test "private broadcast that is sent records :none", %{tenant: tenant, auth_params: auth_params} do
      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)

      stub(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, random_string(), "event", %{"a" => "b"}, :json,
                 private: true
               )

      assert_ingress(:none, :ok)
    end

    test "suspended tenant records :tenant_suspended", %{tenant: tenant} do
      tenant = %{tenant | suspend: true}

      assert {:error, :forbidden, _} =
               SingleBroadcast.broadcast(%Authorization{}, tenant, random_string(), "event", %{"a" => "b"}, :json)

      assert_ingress(:tenant_suspended, :client_error)
    end

    test "invalid message records :invalid_payload", %{tenant: tenant} do
      assert {:error, %Ecto.Changeset{}} =
               SingleBroadcast.broadcast(%Authorization{}, tenant, "", "event", %{"a" => "b"}, :json)

      assert_ingress(:invalid_payload, :client_error)
    end

    # Payload size is checked inside the changeset here, so it shares :invalid_payload. If you split it out
    # into :payload_too_large (the optional refinement in the Step 5 comment), update this test.
    test "payload over the limit records :invalid_payload", %{tenant: tenant} do
      payload = %{"data" => random_string(tenant.max_payload_size_in_kb * 1000 + 1)}

      assert {:error, %Ecto.Changeset{}} =
               SingleBroadcast.broadcast(%Authorization{}, tenant, random_string(), "event", payload, :json)

      assert_ingress(:invalid_payload, :client_error)
    end

    test "rate limited broadcast records :rate_limited", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      stub(RateCounter, :get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}}
      end)

      assert {:error, :too_many_requests, _} =
               SingleBroadcast.broadcast(%Authorization{}, tenant, random_string(), "event", %{"a" => "b"}, :json)

      assert_ingress(:rate_limited, :client_error)
    end

    test "private broadcast denied by policies records :unauthorized", %{tenant: tenant, auth_params: auth_params} do
      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)

      stub(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      assert {:error, :forbidden, "Unauthorized"} =
               SingleBroadcast.broadcast(auth_params, tenant, random_string(), "event", %{"a" => "b"}, :json,
                 private: true
               )

      assert_ingress(:unauthorized, :client_error)
    end

    # Errors from Connect.lookup_or_start_connection/2, mapped by TenantBroadcaster.connect_error_reason/1
    for {connect_error, reason, result} <- [
          {{:error, :rpc_error, :timeout}, :rpc_error, :server_error},
          {{:error, :tenant_database_unavailable}, :tenant_database_unavailable, :tenant_error},
          {{:error, :tenant_db_too_many_connections}, :tenant_db_too_many_connections, :tenant_error},
          {{:error, :connect_rate_limit_reached}, :connect_rate_limit_reached, :tenant_error},
          {{:error, :initializing}, :tenant_initializing, :tenant_error},
          {{:error, :tenant_database_connection_initializing}, :tenant_initializing, :tenant_error},
          {{:error, :tenant_suspended}, :tenant_suspended, :client_error},
          {{:error, :something_unexpected}, :unknown, :server_error}
        ] do
      test "private broadcast when Connect returns #{inspect(connect_error)} records #{inspect(reason)}",
           %{tenant: tenant, auth_params: auth_params} do
        connect_error = unquote(Macro.escape(connect_error))
        stub(Connect, :lookup_or_start_connection, fn _ -> connect_error end)

        capture_log(fn ->
          assert {:error, _status, _message} =
                   SingleBroadcast.broadcast(auth_params, tenant, random_string(), "event", %{"a" => "b"}, :json,
                     private: true
                   )
        end)

        assert_ingress(unquote(reason), unquote(result))
      end
    end

    # Errors from the write authorization check. These don't come from Connect, so SingleBroadcast maps them itself.
    for {auth_error, reason, result} <- [
          {{:error, :rls_policy_error, "policy raised"}, :rls_policy_error, :tenant_error},
          {{:error, :query_canceled, "canceling statement due to statement timeout"}, :query_canceled, :tenant_error},
          {{:error, :missing_partition}, :missing_partition, :server_error},
          {{:error, :increase_connection_pool}, :increase_connection_pool, :tenant_error},
          {{:error, :something_unexpected}, :unknown, :server_error}
        ] do
      test "private broadcast when write authorization returns #{inspect(auth_error)} records #{inspect(reason)}",
           %{tenant: tenant, auth_params: auth_params} do
        auth_error = unquote(Macro.escape(auth_error))
        stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
        stub(Authorization, :get_write_authorizations, fn _, _, :broadcast -> auth_error end)

        capture_log(fn ->
          assert {:error, _status, _message} =
                   SingleBroadcast.broadcast(auth_params, tenant, random_string(), "event", %{"a" => "b"}, :json,
                     private: true
                   )
        end)

        assert_ingress(unquote(reason), unquote(result))
      end
    end
  end

  describe "message persistence" do
    setup %{tenant: tenant} do
      stub(FeatureFlags, :enabled?, fn
        "broadcast_persistence", _tenant_id -> true
        flag, tenant_id -> call_original(FeatureFlags, :enabled?, [flag, tenant_id])
      end)

      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      Tenants.create_messages_partitions(db_conn)

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

      %{db_conn: db_conn, auth_params: auth_params}
    end

    test "stores the message when authorized to persist", %{
      tenant: tenant,
      db_conn: db_conn,
      auth_params: auth_params
    } do
      topic = random_string()
      payload = %{"text" => "hello"}

      expect(GenCounter, :add, fn _ -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(Authorization, :get_write_authorizations, fn _, _, _, :persistence ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: true}}}
      end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", payload, :json,
                 private: true,
                 persist: true
               )

      assert_eventually(
        {:ok,
         [
           %Message{
             topic: ^topic,
             event: "event",
             payload: ^payload,
             extension: :broadcast,
             private: true,
             skip_broadcast: true
           }
         ]} =
          Repo.all(db_conn, messages_for(topic), Message)
      )
    end

    test "does not store the message without a persistence policy", %{
      tenant: tenant,
      db_conn: db_conn,
      auth_params: auth_params
    } do
      topic = random_string()

      expect(GenCounter, :add, fn _ -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(Authorization, :get_write_authorizations, fn _, _, _, :persistence ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: false}}}
      end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"a" => "b"}, :json,
                 private: true,
                 persist: true
               )

      # The policy denies persistence, so no task is spawned and there is nothing to wait for here
      assert {:ok, []} = Repo.all(db_conn, messages_for(topic), Message)
    end

    test "does not store when the request does not ask to persist", %{
      tenant: tenant,
      db_conn: db_conn,
      auth_params: auth_params
    } do
      topic = random_string()

      expect(GenCounter, :add, fn _ -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: true}}}
      end)

      assert :ok = SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"a" => "b"}, :json, private: true)

      assert {:ok, []} = Repo.all(db_conn, messages_for(topic), Message)
    end

    test "rejects persisting a public broadcast", %{tenant: tenant, auth_params: auth_params} do
      topic = random_string()

      assert {:error, %Ecto.Changeset{errors: errors}} =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"a" => "b"}, :json, persist: true)

      assert {:persist, {"can only be used on private channels", []}} in errors
    end

    test "stores binary messages as binary_payload", %{tenant: tenant, db_conn: db_conn, auth_params: auth_params} do
      topic = random_string()
      binary = <<0, 1, 2>>

      expect(GenCounter, :add, fn _ -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(Authorization, :get_write_authorizations, fn _, _, _, :persistence ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: true}}}
      end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", binary, :binary,
                 private: true,
                 persist: true
               )

      assert_eventually(
        {:ok,
         [
           %Message{
             topic: ^topic,
             event: "event",
             payload: nil,
             binary_payload: ^binary,
             extension: :broadcast,
             private: true,
             skip_broadcast: true
           }
         ]} =
          Repo.all(db_conn, messages_for(topic), Message)
      )
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

      expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)

      assert :ok =
               SingleBroadcast.broadcast(auth_params, tenant, topic, "event", %{"secret" => "data"}, :json,
                 private: true
               )
    end
  end

  defp messages_for(topic), do: from(m in Message, where: m.topic == ^topic)

  defp auth_params_fixture(tenant) do
    sub = random_string()
    role = "authenticated"

    Authorization.build_authorization_params(%{
      tenant_id: tenant.external_id,
      headers: [{"header-1", "value-1"}],
      claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
      role: role,
      sub: sub
    })
  end

  # This module runs async and the ingress event has no tenant tag, so a plain handler would also
  # see broadcasts from other tests. SingleBroadcast.broadcast/7 runs in the test process, and telemetry
  # handlers run in the emitting process, so only forward events emitted by this test.
  defp attach_ingress_handler do
    handler_id = {__MODULE__, make_ref()}
    :telemetry.attach(handler_id, [:realtime, :broadcast, :ingress], &__MODULE__.forward_own_ingress/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def forward_own_ingress(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:ingress, measurements, metadata})
  end

  # Exactly one ingress event per request
  defp assert_ingress(reason, result) do
    assert_receive {:ingress, %{count: 1}, metadata},
                   Application.fetch_env!(:ex_unit, :assert_receive_timeout),
                   "expected to receive ingress event with reason #{inspect(reason)} and result #{inspect(result)}"

    assert metadata == %{transport: :http_single, result: result, reason: reason}
    refute_receive {:ingress, _, _}
  end
end
