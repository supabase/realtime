defmodule RealtimeWeb.BroadcastRequestOutcomeTest do
  # The outcomes the HTTP broadcast endpoints record. The single endpoint records one per request.
  # The batch endpoint records one per message, because it answers 202 even when it drops messages.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.RequestMetrics

  @event RequestMetrics.event()

  setup_all do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    %{tenant: tenant}
  end

  # :telemetry_test handlers see events from every process, so outcomes/2 keeps only this tenant's.
  setup %{conn: conn, tenant: tenant} do
    ref = :telemetry_test.attach_event_handlers(self(), [@event])
    Realtime.Tenants.Cache.update_cache(tenant)
    # Drop deliveries counted by previous tests sharing this tenant
    Realtime.GenCounter.reset(Tenants.events_per_second_key(tenant))

    {:ok, conn: generate_conn(conn, tenant), ref: ref}
  end

  defp generate_conn(conn, tenant) do
    now = System.system_time(:second)
    claims = %{role: "test", iat: now, exp: now + 100_000}

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{generate_jwt_token(tenant, claims)}")
    |> then(&%{&1 | host: "#{tenant.external_id}.supabase.com"})
  end

  # The request has already returned, so every event it recorded is in the mailbox.
  defp outcomes(ref, tenant, acc \\ []) do
    tenant_id = tenant.external_id

    receive do
      {@event, ^ref, _measurements, %{tenant: ^tenant_id} = metadata} -> outcomes(ref, tenant, [metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp single(conn, query \\ "", body \\ %{"data" => "test"}) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(Routes.broadcast_single_path(conn, :broadcast, "room:123", "message") <> query, body)
  end

  defp batch(conn, messages), do: post(conn, Routes.broadcast_path(conn, :broadcast), %{"messages" => messages})

  defp message(attrs \\ %{}), do: Map.merge(%{"topic" => "room:123", "event" => "e", "payload" => %{"a" => 1}}, attrs)

  defp private_message(attrs \\ %{}), do: message(Map.put(attrs, "private", true))

  defp oversized(tenant), do: %{"data" => String.duplicate("a", tenant.max_payload_size_in_kb * 1024)}

  defp permit_writes(write?) do
    expect(Authorization, :get_write_authorizations, fn _, _, :broadcast ->
      {:ok, %Policies{broadcast: %BroadcastPolicies{write: write?}}}
    end)
  end

  # RateCounter.get runs twice per request: once in the request rate limiter plug, then once for the
  # events rate. Only the events rate call runs `on_events_rate`; the plug's call reads zero.
  defp expect_events_rate(tenant, on_events_rate) do
    events_per_second_rate = Tenants.events_per_second_rate(tenant)

    expect(RateCounter, :get, 2, fn
      ^events_per_second_rate -> on_events_rate.()
      _ -> {:ok, %RateCounter{avg: 0}}
    end)
  end

  defp dependency_returns(:authorization, result),
    do: expect(Authorization, :get_write_authorizations, fn _, _, :broadcast -> result end)

  defp dependency_returns(:connect, result), do: expect(Connect, :lookup_or_start_connection, fn _ -> result end)

  describe "single broadcast" do
    test "a public broadcast is a success", %{conn: conn, ref: ref, tenant: tenant} do
      assert single(conn).status == 202

      assert [%{request: :broadcast, transport: :http, outcome: :success, reason: :none}] = outcomes(ref, tenant)
    end

    test "a permitted private broadcast is a success", %{conn: conn, ref: ref, tenant: tenant} do
      permit_writes(true)

      assert single(conn, "?private=true").status == 202

      assert [%{request: :broadcast, transport: :http, outcome: :success, reason: :none}] = outcomes(ref, tenant)
    end

    test "a suspended tenant is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      Realtime.Tenants.Cache.update_cache(%{tenant | suspend: true})

      assert single(conn).status == 403

      assert [%{transport: :http, outcome: :rejected, reason: :tenant_suspended}] = outcomes(ref, tenant)
    end

    test "an oversized payload is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      assert single(conn, "", oversized(tenant)).status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :payload_size_exceeded}] = outcomes(ref, tenant)
    end

    # Rejected before SingleBroadcast is called, so the controller has to record it too.
    test "a JSON body that is not an object is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      assert single(conn, "", "[1,2,3]").status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :invalid_request}] = outcomes(ref, tenant)
    end

    test "persist without private is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      assert single(conn, "?persist=true").status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :invalid_request}] = outcomes(ref, tenant)
    end

    # Two errors here, a payload size error and a persist error. The size error names the cause.
    test "a request with several validation errors is counted once", %{conn: conn, ref: ref, tenant: tenant} do
      assert single(conn, "?persist=true", oversized(tenant)).status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :payload_size_exceeded}] = outcomes(ref, tenant)
    end

    test "exceeding the rate limit is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      expect_events_rate(tenant, fn -> {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}} end)

      assert single(conn).status == 429

      assert [%{transport: :http, outcome: :rejected, reason: :rate_limit_exceeded}] = outcomes(ref, tenant)
    end

    test "a denied private broadcast is rejected", %{conn: conn, ref: ref, tenant: tenant} do
      permit_writes(false)

      assert single(conn, "?private=true").status == 403

      assert [%{transport: :http, outcome: :rejected, reason: :unauthorized}] = outcomes(ref, tenant)
    end

    # The status the client sees stays as it is today. The outcome does not come from the status.
    for {name, mock, status, outcome, reason} <- [
          {"rls policy error", {:authorization, {:error, :rls_policy_error, "x"}}, 422, :upstream_failure,
           :rls_policy_error},
          {"query canceled", {:authorization, {:error, :query_canceled, "x"}}, 422, :upstream_failure, :query_canceled},
          {"connection pool exhausted", {:authorization, {:error, :increase_connection_pool}}, 429, :upstream_failure,
           :increase_connection_pool},
          {"tenant database unavailable", {:connect, {:error, :tenant_database_unavailable}}, 422, :upstream_failure,
           :unable_to_connect_to_project},
          {"tenant database initializing", {:connect, {:error, :initializing}}, 422, :upstream_failure,
           :initializing_project_connection},
          {"tenant database connection initializing", {:connect, {:error, :tenant_database_connection_initializing}},
           422, :upstream_failure, :initializing_project_connection},
          {"tenant database has too many connections", {:connect, {:error, :tenant_db_too_many_connections}}, 422,
           :upstream_failure, :database_lack_of_connections},
          {"connect rate limit reached", {:connect, {:error, :connect_rate_limit_reached}}, 422, :upstream_failure,
           :database_connection_rate_limit_reached},
          {"missing messages partition", {:authorization, {:error, :missing_partition}}, 422, :internal_failure,
           :missing_partition},
          {"rpc error", {:connect, {:error, :rpc_error, :timeout}}, 500, :internal_failure,
           :unable_to_handle_broadcast},
          {"unexpected authorization error", {:authorization, {:error, "boom"}}, 500, :internal_failure,
           :unable_to_set_policies}
        ] do
      test "#{name} is #{outcome} (#{reason}) and the client still sees #{status}", %{
        conn: conn,
        ref: ref,
        tenant: tenant
      } do
        {dependency, result} = unquote(Macro.escape(mock))
        dependency_returns(dependency, result)

        assert single(conn, "?private=true").status == unquote(status)

        assert [%{transport: :http, outcome: unquote(outcome), reason: unquote(reason)}] = outcomes(ref, tenant)
      end
    end

    test "a crash is an internal failure", %{conn: conn, ref: ref, tenant: tenant} do
      expect_events_rate(tenant, fn -> raise "boom" end)

      assert_raise_any(fn -> single(conn) end)

      assert [%{request: :broadcast, transport: :http, outcome: :internal_failure, reason: :error}] =
               outcomes(ref, tenant)
    end

    test "exactly one outcome per request", %{conn: conn, ref: ref, tenant: tenant} do
      single(conn)
      single(conn)

      assert [%{outcome: :success}, %{outcome: :success}] = outcomes(ref, tenant)
    end
  end

  describe "batch broadcast" do
    test "every message of an accepted batch is a success", %{conn: conn, ref: ref, tenant: tenant} do
      assert batch(conn, [message(), message(), message()]).status == 202

      assert [
               %{request: :broadcast, transport: :http, outcome: :success, reason: :none},
               %{outcome: :success},
               %{outcome: :success}
             ] = outcomes(ref, tenant)
    end

    test "permitted private messages are a success", %{conn: conn, ref: ref, tenant: tenant} do
      permit_writes(true)

      assert batch(conn, [private_message(), private_message()]).status == 202

      assert [%{outcome: :success}, %{outcome: :success}] = outcomes(ref, tenant)
    end

    test "denied private messages are rejected per message even though the batch answers 202", %{
      conn: conn,
      ref: ref,
      tenant: tenant
    } do
      permit_writes(false)

      assert batch(conn, [private_message(), private_message(), private_message()]).status == 202

      assert [
               %{transport: :http, outcome: :rejected, reason: :unauthorized},
               %{outcome: :rejected, reason: :unauthorized},
               %{outcome: :rejected, reason: :unauthorized}
             ] = outcomes(ref, tenant)
    end

    test "messages dropped by an upstream failure are upstream failures per message, with a 202", %{
      conn: conn,
      ref: ref,
      tenant: tenant
    } do
      dependency_returns(:connect, {:error, :tenant_database_unavailable})

      assert batch(conn, [private_message(), private_message()]).status == 202

      assert [
               %{transport: :http, outcome: :upstream_failure, reason: :unable_to_connect_to_project},
               %{outcome: :upstream_failure, reason: :unable_to_connect_to_project}
             ] = outcomes(ref, tenant)
    end

    # The messages are dropped and the batch still answers 202, so only the outcome shows the cause.
    for {name, mock, outcome, reason} <- [
          {"tenant database initializing", {:connect, {:error, :initializing}}, :upstream_failure,
           :initializing_project_connection},
          {"tenant database connection initializing", {:connect, {:error, :tenant_database_connection_initializing}},
           :upstream_failure, :initializing_project_connection},
          {"tenant database has too many connections", {:connect, {:error, :tenant_db_too_many_connections}},
           :upstream_failure, :database_lack_of_connections},
          {"connect rate limit reached", {:connect, {:error, :connect_rate_limit_reached}}, :upstream_failure,
           :database_connection_rate_limit_reached},
          {"rpc error", {:connect, {:error, :rpc_error, :timeout}}, :internal_failure, :unable_to_handle_broadcast},
          {"rls policy error", {:authorization, {:error, :rls_policy_error, "x"}}, :upstream_failure,
           :rls_policy_error},
          {"query canceled", {:authorization, {:error, :query_canceled, "x"}}, :upstream_failure, :query_canceled},
          {"connection pool exhausted", {:authorization, {:error, :increase_connection_pool}}, :upstream_failure,
           :increase_connection_pool},
          {"missing messages partition", {:authorization, {:error, :missing_partition}}, :internal_failure,
           :missing_partition},
          {"unexpected authorization error", {:authorization, {:error, "boom"}}, :internal_failure,
           :unable_to_set_policies}
        ] do
      test "#{name} drops the messages as #{outcome} (#{reason}), with a 202", %{conn: conn, ref: ref, tenant: tenant} do
        {dependency, result} = unquote(Macro.escape(mock))
        dependency_returns(dependency, result)

        assert batch(conn, [private_message(), private_message()]).status == 202

        assert [
                 %{transport: :http, outcome: unquote(outcome), reason: unquote(reason)},
                 %{outcome: unquote(outcome), reason: unquote(reason)}
               ] = outcomes(ref, tenant)
      end
    end

    test "topics in one batch are classified separately", %{conn: conn, ref: ref, tenant: tenant} do
      expect(Authorization, :get_write_authorizations, 2, fn _, %{topic: topic}, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: topic == "room:allowed"}}}
      end)

      messages = [
        private_message(%{"topic" => "room:denied"}),
        private_message(%{"topic" => "room:allowed"}),
        private_message(%{"topic" => "room:denied"})
      ]

      assert batch(conn, messages).status == 202

      outcomes = outcomes(ref, tenant)

      assert [:rejected, :rejected, :success] = outcomes |> Enum.map(& &1.outcome) |> Enum.sort()
      assert [:unauthorized, :unauthorized] = for(%{outcome: :rejected, reason: reason} <- outcomes, do: reason)
    end

    test "a mixed batch is counted message by message", %{conn: conn, ref: ref, tenant: tenant} do
      permit_writes(false)

      assert batch(conn, [message(), private_message(), message()]).status == 202

      assert [:rejected, :success, :success] = outcomes(ref, tenant) |> Enum.map(& &1.outcome) |> Enum.sort()
    end

    # Messages to the same topic share one authorization check, but each one is counted.
    test "messages to the same private topic are each counted", %{conn: conn, ref: ref, tenant: tenant} do
      expect(Authorization, :get_write_authorizations, 1, fn _, _, :broadcast ->
        {:ok, %Policies{broadcast: %BroadcastPolicies{write: true}}}
      end)

      batch(conn, [private_message(), private_message()])

      assert [%{outcome: :success}, %{outcome: :success}] = outcomes(ref, tenant)
    end

    # A valid message is only dropped with its batch, so it gets :batch_rejected.
    test "each message of a rejected batch gets its own reason", %{conn: conn, ref: ref, tenant: tenant} do
      messages = [
        message(),
        %{"topic" => "room:123"},
        message(),
        message(%{"payload" => oversized(tenant)})
      ]

      assert batch(conn, messages).status == 422

      assert [
               %{transport: :http, outcome: :rejected, reason: :batch_rejected},
               %{outcome: :rejected, reason: :invalid_request},
               %{outcome: :rejected, reason: :batch_rejected},
               %{outcome: :rejected, reason: :payload_size_exceeded}
             ] = outcomes(ref, tenant)
    end

    test "a message with a size error and another error is counted as oversized", %{
      conn: conn,
      ref: ref,
      tenant: tenant
    } do
      invalid_and_oversized = %{"topic" => "room:123", "payload" => oversized(tenant)}

      assert batch(conn, [invalid_and_oversized]).status == 422

      assert [%{outcome: :rejected, reason: :payload_size_exceeded}] = outcomes(ref, tenant)
    end

    # Without a list there are no messages to build changesets for, so the request is one rejection.
    test "input that is not a list of messages is counted once as invalid", %{conn: conn, ref: ref, tenant: tenant} do
      assert batch(conn, "not a list").status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :invalid_request}] = outcomes(ref, tenant)
    end

    # A message that is not an object makes Ecto reject the whole list, so there are no message
    # changesets. Each entry still counts, as invalid_request.
    test "a list with entries that are not objects counts every entry as invalid", %{
      conn: conn,
      ref: ref,
      tenant: tenant
    } do
      assert batch(conn, [message(), "oops", message(%{"payload" => oversized(tenant)})]).status == 422

      assert [
               %{transport: :http, outcome: :rejected, reason: :invalid_request},
               %{outcome: :rejected, reason: :invalid_request},
               %{outcome: :rejected, reason: :invalid_request}
             ] = outcomes(ref, tenant)
    end

    test "an oversized message is rejected as payload_size_exceeded", %{conn: conn, ref: ref, tenant: tenant} do
      assert batch(conn, [message(%{"payload" => oversized(tenant)})]).status == 422

      assert [%{transport: :http, outcome: :rejected, reason: :payload_size_exceeded}] = outcomes(ref, tenant)
    end

    test "a suspended tenant rejects every message", %{conn: conn, ref: ref, tenant: tenant} do
      Realtime.Tenants.Cache.update_cache(%{tenant | suspend: true})

      assert batch(conn, [message(), message()]).status == 403

      assert [
               %{outcome: :rejected, reason: :tenant_suspended},
               %{outcome: :rejected, reason: :tenant_suspended}
             ] = outcomes(ref, tenant)
    end

    test "exceeding the rate limit rejects every message", %{conn: conn, ref: ref, tenant: tenant} do
      expect_events_rate(tenant, fn -> {:ok, %RateCounter{avg: tenant.max_events_per_second + 1}} end)

      assert batch(conn, [message(), message()]).status == 429

      assert [
               %{outcome: :rejected, reason: :rate_limit_exceeded},
               %{outcome: :rejected, reason: :rate_limit_exceeded}
             ] = outcomes(ref, tenant)
    end

    test "a crash is one internal failure", %{conn: conn, ref: ref, tenant: tenant} do
      expect_events_rate(tenant, fn -> raise "boom" end)

      assert_raise_any(fn -> batch(conn, [message(), message()]) end)

      # The crash happens before the messages are known to be valid, so it counts once.
      assert [%{transport: :http, outcome: :internal_failure, reason: :error}] = outcomes(ref, tenant)
    end
  end

  # Requests that fail in a plug before the controller (bad JWT, unknown tenant, unsupported content
  # type) are not counted.
  describe "requests rejected before the controller" do
    test "a missing JWT is not counted", %{conn: conn, ref: ref, tenant: tenant} do
      conn = delete_req_header(conn, "authorization")

      assert single(conn).status == 401

      assert [] = outcomes(ref, tenant)
    end
  end

  # The exception type depends on how Phoenix wraps it, and only the outcome matters here.
  defp assert_raise_any(fun) do
    raised? =
      try do
        fun.()
        false
      rescue
        _ -> true
      end

    assert raised?, "expected the request to raise"
  end
end
