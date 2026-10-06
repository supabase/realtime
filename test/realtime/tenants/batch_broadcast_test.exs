defmodule Realtime.Tenants.BatchBroadcastTest do
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
  alias Realtime.Tenants.BatchBroadcast
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Repo

  alias RealtimeWeb.TenantBroadcaster

  setup_all do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    Realtime.Tenants.Cache.update_cache(tenant)
    {:ok, tenant: tenant}
  end

  describe "public message broadcasting" do
    test "broadcasts multiple public messages successfully", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic1 = random_string()
      topic2 = random_string()

      messages = %{
        messages: [
          %{topic: topic1, payload: %{"data" => "test1"}, event: "event1"},
          %{topic: topic2, payload: %{"data" => "test2"}, event: "event2"},
          %{topic: topic1, payload: %{"data" => "test3"}, event: "event3"}
        ]
      }

      expect(GenCounter, :add, 3, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, 3, fn _, _, _, _, _ -> :ok end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, false)
    end

    test "public messages do not have private prefix in topic", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      messages = %{
        messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1"}]
      }

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, topic, _, _, _ ->
        refute String.contains?(topic, "-private")
      end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, false)
    end
  end

  describe "message ID metadata" do
    test "includes message ID in metadata when provided", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      messages = %{
        messages: [%{id: "msg-123", topic: topic, payload: %{"data" => "test"}, event: "event1"}]
      }

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, broadcast, _, _ ->
        assert %Phoenix.Socket.Broadcast{
                 payload: %{
                   "payload" => %{"data" => "test"},
                   "event" => "event1",
                   "type" => "broadcast",
                   "meta" => %{"id" => "msg-123"}
                 }
               } = broadcast
      end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, false)
    end
  end

  describe "super user broadcasting" do
    test "bypasses authorization for private messages with super_user flag", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic1 = random_string()
      topic2 = random_string()

      messages = %{
        messages: [
          %{topic: topic1, payload: %{"data" => "test1"}, event: "event1", private: true},
          %{topic: topic2, payload: %{"data" => "test2"}, event: "event2", private: true}
        ]
      }

      expect(GenCounter, :add, 2, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, 2, fn _, _, _, _, _ -> :ok end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, true)
    end

    test "private messages have private prefix in topic", %{tenant: tenant} do
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      topic = random_string()

      messages = %{
        messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1", private: true}]
      }

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      expect(TenantBroadcaster, :pubsub_broadcast, fn _, topic, _, _, _ ->
        assert String.contains?(topic, "-private")
      end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, true)
    end
  end

  describe "private message authorization" do
    test "broadcasts private messages with valid authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      auth_params = %{
        tenant_id: tenant.external_id,
        topic: topic,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      messages = %{messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1", private: true}]}

      broadcast_events_key = Tenants.events_per_second_key(tenant)

      expect(GenCounter, :add, 1, fn ^broadcast_events_key -> :ok end)

      Authorization
      |> expect(:build_authorization_params, fn params -> params end)
      |> expect(:get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, 1, fn _, _, _, _, _ -> :ok end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)
    end

    test "skips private messages without authorization", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "anon"

      auth_params = %{
        tenant_id: tenant.external_id,
        topic: topic,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      Authorization
      |> expect(:build_authorization_params, 1, fn params -> params end)
      |> expect(:get_write_authorizations, 1, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      messages = %{
        messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1", private: true}]
      }

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end

    test "broadcasts only authorized topics in mixed authorization batch", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      auth_params = %{
        tenant_id: tenant.external_id,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      messages = %{
        messages: [
          %{topic: topic, payload: %{"data" => "test1"}, event: "event1", private: true},
          %{topic: random_string(), payload: %{"data" => "test2"}, event: "event2", private: true}
        ]
      }

      broadcast_events_key = Tenants.events_per_second_key(tenant)

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)

      Authorization
      |> expect(:build_authorization_params, 2, fn params -> params end)
      |> expect(:get_write_authorizations, 2, fn
        _, %{topic: ^topic}, :broadcast -> {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
        _, _, :broadcast -> {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      # Only one topic will actually be broadcasted
      expect(TenantBroadcaster, :pubsub_broadcast, 1, fn _, _, %Phoenix.Socket.Broadcast{topic: ^topic}, _, _ ->
        :ok
      end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)
    end

    test "groups messages by topic and checks authorization once per topic", %{tenant: tenant} do
      topic_1 = random_string()
      topic_2 = random_string()
      sub = random_string()
      role = "authenticated"

      auth_params = %{
        tenant_id: tenant.external_id,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      messages = %{
        messages: [
          %{topic: topic_1, payload: %{"data" => "test1"}, event: "event1", private: true},
          %{topic: topic_2, payload: %{"data" => "test2"}, event: "event2", private: true},
          %{topic: topic_1, payload: %{"data" => "test3"}, event: "event3", private: true}
        ]
      }

      broadcast_events_key = Tenants.events_per_second_key(tenant)

      expect(GenCounter, :add, 3, fn ^broadcast_events_key -> :ok end)

      Authorization
      |> expect(:build_authorization_params, 2, fn params -> params end)
      |> expect(:get_write_authorizations, 2, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, 3, fn _, _, _, _, _ -> :ok end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)
    end

    test "handles missing auth params for private messages", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: 0}} end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)
      reject(&Connect.lookup_or_start_connection/1)

      messages = %{
        messages: [%{topic: "topic1", payload: %{"data" => "test"}, event: "event1", private: true}]
      }

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  describe "mixed public and private messages" do
    setup %{tenant: tenant} do
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
      %{db_conn: db_conn}
    end

    test "broadcasts both public and private messages together", %{tenant: tenant, db_conn: db_conn} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      create_rls_policies(db_conn, [:authenticated_write_broadcast], %{topic: topic})

      auth_params = %{
        tenant_id: tenant.external_id,
        topic: topic,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      broadcast_events_key = Tenants.events_per_second_key(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn
        ^events_per_second_rate ->
          {:ok, %RateCounter{avg: 0}}

        _ ->
          {:ok,
           %RateCounter{
             avg: 0,
             limit: %{log: true, value: 10, measurement: :sum, triggered: false, log_fn: fn -> :ok end}
           }}
      end)

      expect(GenCounter, :add, 3, fn ^broadcast_events_key -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)

      Authorization
      |> expect(:build_authorization_params, fn params -> params end)
      |> expect(:get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      expect(TenantBroadcaster, :pubsub_broadcast, 3, fn _, _, _, _, _ -> :ok end)

      messages = %{
        messages: [
          %{topic: "public1", payload: %{"data" => "public"}, event: "event1", private: false},
          %{topic: topic, payload: %{"data" => "private"}, event: "event2", private: true},
          %{topic: "public2", payload: %{"data" => "public2"}, event: "event3"}
        ]
      }

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)

      broadcast_calls = calls(&TenantBroadcaster.pubsub_broadcast/5)
      assert length(broadcast_calls) == 3
    end
  end

  describe "Plug.Conn integration" do
    test "accepts and converts Plug.Conn to auth params", %{tenant: tenant} do
      topic = random_string()
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      messages = %{messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1"}]}

      expect(GenCounter, :add, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, 1, fn _, _, _, _, _ -> :ok end)

      conn =
        build_conn()
        |> Map.put(:assigns, %{
          claims: %{"sub" => "user123", "role" => "authenticated"},
          role: "authenticated",
          sub: "user123"
        })
        |> Map.put(:req_headers, [{"authorization", "Bearer token"}])

      assert :ok = BatchBroadcast.broadcast(conn, tenant, messages, false)
    end
  end

  describe "message validation" do
    test "returns changeset error when topic is missing", %{tenant: tenant} do
      messages = %{messages: [%{payload: %{"data" => "test"}, event: "event1"}]}

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when payload is missing", %{tenant: tenant} do
      topic = random_string()
      messages = %{messages: [%{topic: topic, event: "event1"}]}

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when event is missing", %{tenant: tenant} do
      topic = random_string()
      messages = %{messages: [%{topic: topic, payload: %{"data" => "test"}}]}

      reject(&TenantBroadcaster.pubsub_broadcast/5)
      result = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end

    test "returns changeset error when messages array is empty", %{tenant: tenant} do
      messages = %{messages: []}
      reject(&TenantBroadcaster.pubsub_broadcast/5)
      result = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert {:error, %Ecto.Changeset{valid?: false}} = result
    end
  end

  describe "rate limiting" do
    test "rejects broadcast when rate limit is exceeded", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      topic = random_string()
      messages = %{messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1"}]}

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}} end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert {:error, :too_many_requests, "You have exceeded your rate limit"} = result
    end

    test "rejects broadcast when batch would exceed rate limit", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      messages = %{
        messages:
          Enum.map(1..10, fn _ ->
            %{topic: random_string(), payload: %{"data" => "test"}, event: random_string()}
          end)
      }

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: tenant.max_events_per_second - 5}}
      end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert {:error, :too_many_requests, "Too many messages to broadcast, please reduce the batch size"} = result
    end

    test "allows broadcast at rate limit boundary", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)
      broadcast_events_key = Tenants.events_per_second_key(tenant)
      current_rate = tenant.max_events_per_second - 2

      messages = %{
        messages: [
          %{topic: random_string(), payload: %{"data" => "test1"}, event: "event1"},
          %{topic: random_string(), payload: %{"data" => "test2"}, event: "event2"}
        ]
      }

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: current_rate}}
      end)

      expect(GenCounter, :add, 2, fn ^broadcast_events_key -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, 2, fn _, _, _, _, _ -> :ok end)

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, false)
    end

    test "rejects broadcast when payload size exceeds tenant limit", %{tenant: tenant} do
      messages = %{
        messages: [
          %{
            topic: random_string(),
            payload: %{"data" => random_string(tenant.max_payload_size_in_kb * 1000 + 1)},
            event: "event1"
          }
        ]
      }

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      result = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert {:error,
              %Ecto.Changeset{
                valid?: false,
                changes: %{messages: [%{errors: [payload: {"Payload size exceeds tenant limit", []}]}]}
              }} = result
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
      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
      stub(Authorization, :build_authorization_params, fn params -> params end)

      %{auth_params: auth_params_fixture(tenant)}
    end

    test "public messages record :none once with the number of public messages", %{tenant: tenant} do
      assert :ok = BatchBroadcast.broadcast(nil, tenant, batch(public: 3), false)

      assert_ingress_events([{:none, :ok, 3}])
    end

    test "super user private messages record :none once per topic", %{tenant: tenant} do
      [topic_a, topic_b] = [random_string(), random_string()]
      messages = batch(private: [{topic_a, 2}, {topic_b, 1}])

      assert :ok = BatchBroadcast.broadcast(nil, tenant, messages, true)

      assert_ingress_events([{:none, :ok, 2}, {:none, :ok, 1}])
    end

    test "authorized private messages record :none once per topic", %{tenant: tenant, auth_params: auth_params} do
      stub(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, batch(private: [{random_string(), 2}]), false)

      assert_ingress_events([{:none, :ok, 2}])
    end

    test "private messages denied by policies record :unauthorized", %{tenant: tenant, auth_params: auth_params} do
      stub(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: false}}}
      end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, batch(private: [{random_string(), 2}]), false)

      assert_ingress_events([{:unauthorized, :client_error, 2}])
    end

    test "private messages with no matching policy record :unauthorized", %{tenant: tenant, auth_params: auth_params} do
      stub(Authorization, :get_write_authorizations, fn _, _, :broadcast -> {:error, :not_found} end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, batch(private: [{random_string(), 1}]), false)

      assert_ingress_events([{:unauthorized, :client_error, 1}])
    end

    test "private messages without auth params record :unauthorized", %{tenant: tenant} do
      assert :ok = BatchBroadcast.broadcast(nil, tenant, batch(private: [{random_string(), 2}]), false)

      assert_ingress_events([{:unauthorized, :client_error, 2}])
    end

    test "mixed batch records one event per group and the counts add up to the batch size",
         %{tenant: tenant, auth_params: auth_params} do
      [allowed, denied] = [random_string(), random_string()]

      stub(Authorization, :get_write_authorizations, fn _, %{topic: topic}, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: topic == allowed}}}
      end)

      messages = batch(public: 2, private: [{allowed, 2}, {denied, 1}])

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)

      events = assert_ingress_events([{:none, :ok, 2}, {:none, :ok, 2}, {:unauthorized, :client_error, 1}])
      assert events |> Enum.map(fn {_reason, _result, count} -> count end) |> Enum.sum() == 5
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
      test "private messages when Connect returns #{inspect(connect_error)} record #{inspect(reason)}",
           %{tenant: tenant, auth_params: auth_params} do
        connect_error = unquote(Macro.escape(connect_error))
        stub(Connect, :lookup_or_start_connection, fn _ -> connect_error end)

        capture_log(fn ->
          assert :ok = BatchBroadcast.broadcast(auth_params, tenant, batch(private: [{random_string(), 2}]), false)
        end)

        assert_ingress_events([{unquote(reason), unquote(result), 2}])
      end
    end

    # Errors from the write authorization check. These don't come from Connect, so BatchBroadcast maps them itself.
    for {auth_error, reason, result} <- [
          {{:error, :rls_policy_error, "policy raised"}, :rls_policy_error, :tenant_error},
          {{:error, :query_canceled, "canceling statement due to statement timeout"}, :query_canceled, :tenant_error},
          {{:error, :missing_partition}, :missing_partition, :server_error},
          {{:error, :increase_connection_pool}, :increase_connection_pool, :tenant_error},
          {{:error, :something_unexpected}, :unknown, :server_error}
        ] do
      test "private messages when write authorization returns #{inspect(auth_error)} record #{inspect(reason)}",
           %{tenant: tenant, auth_params: auth_params} do
        auth_error = unquote(Macro.escape(auth_error))
        stub(Authorization, :get_write_authorizations, fn _, _, :broadcast -> auth_error end)

        capture_log(fn ->
          assert :ok = BatchBroadcast.broadcast(auth_params, tenant, batch(private: [{random_string(), 2}]), false)
        end)

        assert_ingress_events([{unquote(reason), unquote(result), 2}])
      end
    end

    # The request is rejected before its messages are parsed, so there's no trusted message count. It counts as one.
    test "suspended tenant records :tenant_suspended once", %{tenant: tenant} do
      tenant = %{tenant | suspend: true}

      assert {:error, :forbidden, _} = BatchBroadcast.broadcast(nil, tenant, batch(public: 3), false)

      assert_ingress_events([{:tenant_suspended, :client_error, 1}])
    end

    # Same as above: an invalid changeset has no trusted message count.
    test "invalid batch records :invalid_payload once", %{tenant: tenant} do
      messages = %{messages: [%{payload: %{"data" => "test"}, event: "event1"}, %{topic: random_string()}]}

      assert {:error, %Ecto.Changeset{}} = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert_ingress_events([{:invalid_payload, :client_error, 1}])
    end

    test "payload over the limit records :invalid_payload once", %{tenant: tenant} do
      payload = %{"data" => random_string(tenant.max_payload_size_in_kb * 1000 + 1)}
      messages = %{messages: [%{topic: random_string(), payload: payload, event: "event1"}]}

      assert {:error, %Ecto.Changeset{}} = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert_ingress_events([{:invalid_payload, :client_error, 1}])
    end

    test "rate limited batch records :rate_limited with the number of messages", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      stub(RateCounter, :get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}}
      end)

      assert {:error, :too_many_requests, _} = BatchBroadcast.broadcast(nil, tenant, batch(public: 3), false)

      assert_ingress_events([{:rate_limited, :client_error, 3}])
    end

    # BroadcastController passes Phoenix params straight through, and those have string keys
    test "rate limited batch with string keys records :rate_limited with the number of messages", %{tenant: tenant} do
      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      stub(RateCounter, :get, fn ^events_per_second_rate ->
        {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}}
      end)

      messages = %{
        "messages" =>
          for i <- 1..3 do
            %{"topic" => random_string(), "payload" => %{"data" => "public #{i}"}, "event" => "event"}
          end
      }

      assert {:error, :too_many_requests, _} = BatchBroadcast.broadcast(nil, tenant, messages, false)

      assert_ingress_events([{:rate_limited, :client_error, 3}])
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

      auth_params = %{
        tenant_id: tenant.external_id,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      %{db_conn: db_conn, auth_params: auth_params}
    end

    test "the batch API never stores messages, even when authorized to persist", %{
      tenant: tenant,
      db_conn: db_conn,
      auth_params: auth_params
    } do
      topic = random_string()
      messages = %{messages: [%{topic: topic, payload: %{"data" => "x"}, event: "event1", private: true}]}

      expect(GenCounter, :add, fn _ -> :ok end)
      expect(TenantBroadcaster, :pubsub_broadcast, fn _, _, _, _, _ -> :ok end)
      expect(Connect, :lookup_or_start_connection, fn _ -> {:ok, db_conn} end)

      Authorization
      |> expect(:build_authorization_params, fn params -> params end)
      |> expect(:get_write_authorizations, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true, persist: true}}}
      end)

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)

      refute_eventually match?({:ok, [_ | _]}, Repo.all(db_conn, messages_for(topic), Message))
    end
  end

  describe "error handling" do
    test "returns error when tenant is nil" do
      messages = %{messages: [%{topic: "topic1", payload: %{"data" => "test"}, event: "event1"}]}
      assert {:error, :tenant_not_found} = BatchBroadcast.broadcast(nil, nil, messages, false)
    end

    test "does not broadcast when tenant is suspended", %{tenant: tenant} do
      tenant = %{tenant | suspend: true}
      messages = %{messages: [%{topic: "topic1", payload: %{"data" => "test"}, event: "event1"}]}

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      assert {:error, :forbidden, "Tenant is suspended"} = BatchBroadcast.broadcast(nil, tenant, messages, false)
      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end

    test "gracefully handles database connection errors for private messages", %{tenant: tenant} do
      topic = random_string()
      sub = random_string()
      role = "authenticated"

      auth_params = %{
        tenant_id: tenant.external_id,
        headers: [{"header-1", "value-1"}],
        claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
        role: role,
        sub: sub
      }

      events_per_second_rate = Tenants.events_per_second_rate(tenant)

      RateCounter
      |> stub(:new, fn _ -> {:ok, nil} end)
      |> stub(:get, fn ^events_per_second_rate -> {:ok, %RateCounter{avg: 0}} end)

      expect(Connect, :lookup_or_start_connection, fn _ -> {:error, :connection_failed} end)

      reject(&TenantBroadcaster.pubsub_broadcast/5)

      messages = %{
        messages: [%{topic: topic, payload: %{"data" => "test"}, event: "event1", private: true}]
      }

      assert :ok = BatchBroadcast.broadcast(auth_params, tenant, messages, false)

      assert calls(&TenantBroadcaster.pubsub_broadcast/5) == []
    end
  end

  defp messages_for(topic), do: from(m in Message, where: m.topic == ^topic)

  # Builds a batch with `public: n` public messages and `private: [{topic, n}, ...]` private messages
  defp batch(opts) do
    public =
      for i <- 1..Keyword.get(opts, :public, 0)//1 do
        %{topic: random_string(), payload: %{"data" => "public #{i}"}, event: "event"}
      end

    private =
      for {topic, count} <- Keyword.get(opts, :private, []), i <- 1..count//1 do
        %{topic: topic, payload: %{"data" => "private #{i}"}, event: "event", private: true}
      end

    %{messages: public ++ private}
  end

  defp auth_params_fixture(tenant) do
    sub = random_string()
    role = "authenticated"

    %{
      tenant_id: tenant.external_id,
      headers: [{"header-1", "value-1"}],
      claims: %{"sub" => sub, "role" => role, "exp" => Joken.current_time() + 1_000},
      role: role,
      sub: sub
    }
  end

  # This module runs async and the ingress event has no tenant tag, so a plain handler would also
  # see broadcasts from other tests. BatchBroadcast.broadcast/4 runs in the test process, and telemetry
  # handlers run in the emitting process, so only forward events emitted by this test.
  defp attach_ingress_handler do
    handler_id = {__MODULE__, make_ref()}
    :telemetry.attach(handler_id, [:realtime, :broadcast, :ingress], &__MODULE__.forward_own_ingress/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def forward_own_ingress(_event, measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:ingress, measurements, metadata})
  end

  # A batch emits one event per group, so compare every event received as an unordered list of
  # {reason, result, count}. Telemetry handlers run synchronously in this process, so all events are
  # already in the mailbox when broadcast/4 returns.
  defp assert_ingress_events(expected) do
    received = receive_ingress_events([])

    assert Enum.all?(received, fn {transport, _reason, _result, _count} -> transport == :http_batch end)

    received = Enum.map(received, fn {_transport, reason, result, count} -> {reason, result, count} end)
    assert Enum.sort(received) == Enum.sort(expected)
    received
  end

  defp receive_ingress_events(acc) do
    receive do
      {:ingress, %{count: count}, %{transport: transport, reason: reason, result: result}} ->
        receive_ingress_events([{transport, reason, result, count} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
