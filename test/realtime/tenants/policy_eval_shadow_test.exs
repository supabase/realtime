defmodule Realtime.Tenants.PolicyEvalShadowTest do
  # Realtime.Tenants.PolicyEvalShadow: never affects the real result, records agreement/disagreement.
  # Tests synchronise on telemetry messages, no sleeps: the :timing event is always the last thing the
  # shadow task does, so waiting for it proves everything before it (including a mismatch's log_warning,
  # same process, same mailbox, FIFO) has already happened.
  #
  # :telemetry.attach is global and these event names are shared across every test in this file, so
  # under async: true a concurrently-running test's events would otherwise land in the wrong mailbox.
  # Each test uses its own unique tenant_id and pins it (`tenant: ^tenant_id`) in every telemetry
  # pattern below, so a message that actually belongs to a different test can never match.
  use RealtimeWeb.ConnCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  setup :set_mimic_from_context

  alias Realtime.FeatureFlags
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.PolicyEvalCache
  alias Realtime.Tenants.PolicyEvalEnv
  alias Realtime.Tenants.PolicyEvalProfile
  alias Realtime.Tenants.PolicyEvalShadow

  @flag "policy_eval_shadow"
  @read_decision [:realtime, :tenants, :policy_eval, :shadow, :read]
  @read_timing [:realtime, :tenants, :policy_eval, :shadow, :read, :timing]
  @read_unavailable [:realtime, :tenants, :policy_eval, :shadow, :read, :unavailable]
  @read_exception [:realtime, :tenants, :policy_eval, :shadow, :read, :exception]
  @write_decision [:realtime, :tenants, :policy_eval, :shadow, :write]
  @write_timing [:realtime, :tenants, :policy_eval, :shadow, :write, :timing]

  defp unique_tenant_id, do: "tenant_#{System.unique_integer([:positive])}"

  defp context(opts) do
    Authorization.build_authorization_params(%{
      tenant_id: Keyword.fetch!(opts, :tenant_id),
      topic: Keyword.get(opts, :topic, "room:1"),
      headers: [],
      claims: Keyword.get(opts, :claims, %{"role" => "authenticated"}),
      role: Keyword.get(opts, :role, "authenticated"),
      sub: Keyword.get(opts, :sub)
    })
  end

  # A one-policy snapshot: permissive, SELECT and INSERT, unconditionally true. Decides :allow for
  # both reads and writes by "anon" and "authenticated", with no dependency on topic/sub/extension.
  defp always_allow_snapshot do
    privileges = %{bypass_rls: false, select: true, insert: true}

    PolicyEval.Snapshot.new(
      %{
        rls_enabled: true,
        rls_forced: false,
        roles: %{"anon" => privileges, "authenticated" => privileges},
        policies: [
          %{name: "p", cmd: "*", permissive: true, roles: ["anon", "authenticated"], qual: "true", with_check: nil}
        ]
      },
      PolicyEvalProfile.profile()
    )
  end

  # What Authorization's handle_policies_result/2 returns for any Postgrex.Error from the check.
  defp policy_error(code, pg_code, message),
    do: {:error, :rls_policy_error, %Postgrex.Error{postgres: %{code: code, pg_code: pg_code, message: message}}}

  defp attach(event) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn event, measurements, metadata, _config -> send(test_pid, {:telemetry, ref, event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  describe "read/4" do
    test "flag off (the default): no task runs, the cache is never touched" do
      # A detached Task.Supervisor.start_child task is unlinked: if it crashed on a reject violation,
      # that crash would be invisible to this process. :timing is the last thing a run always emits, on
      # every path (decided, mismatched, unavailable) — its absence is what actually proves nothing ran.
      tenant_id = unique_tenant_id()
      reject(&PolicyEvalCache.fetch/2)
      timing_ref = attach(@read_timing)

      assert :ok = PolicyEvalShadow.read(:fake_conn, context(tenant_id: tenant_id), [:broadcast], {:ok, %Policies{}})
      refute_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 100
    end

    test "agreement: outcome is :match, nothing is logged" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)

      ctx = context(tenant_id: tenant_id)
      result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}

      log =
        capture_log(fn ->
          assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], result)
          assert_receive {:telemetry, ^timing_ref, _event, measurements, %{tenant: ^tenant_id}}, 2000
          assert is_integer(measurements.shadow_duration)
        end)

      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :match
      assert decision_metadata.real == true
      assert decision_metadata.reason == :none
      assert decision_metadata.role == "authenticated"
      refute log =~ "PolicyEvalShadowMismatch"
    end

    test "role: names only the profile's and platform roles, :other for a tenant's role, :none without one" do
      # Only a role policy_eval decides gets past the role check; every other role falls back as :role.
      for {role, reason, tag} <- [
            {"authenticated", :none, "authenticated"},
            {"anon", :none, "anon"},
            # Not an official role name we support
            {"anonymous", :role, :other},
            {"service_role", :role, "service_role"},
            {"app_writer", :role, :other},
            {nil, :role, :none}
          ] do
        tenant_id = unique_tenant_id()
        expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
        expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

        decision_ref = attach(@read_decision)
        timing_ref = attach(@read_timing)

        ctx = context(tenant_id: tenant_id, role: role, claims: %{"role" => role})
        result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}

        assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], result)
        assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
        assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
        assert {decision_metadata.reason, decision_metadata.role} == {reason, tag}
      end
    end

    test "fallback: records outcome: :fallback with the reason's category, nothing is logged" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)

      # service_role isn't one of the roles policy_eval models: {:fallback, {:role, "service_role"}}
      ctx = context(tenant_id: tenant_id, role: "service_role", claims: %{"role" => "service_role"})
      result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: true}}}

      log =
        capture_log(fn ->
          assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], result)
          assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
        end)

      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :fallback
      assert decision_metadata.reason == :role
      assert decision_metadata.real == true
      refute log =~ "PolicyEvalShadowMismatch"
    end

    test "mismatch: logs a warning and records outcome: :mismatch" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      timing_ref = attach(@read_timing)
      decision_ref = attach(@read_decision)

      ctx = context(tenant_id: tenant_id)
      # The real check denied it; the (stubbed) snapshot always allows authenticated reads.
      result = {:ok, %Policies{broadcast: %BroadcastPolicies{read: false}}}

      log =
        capture_log(fn ->
          assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], result)
          assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
        end)

      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :mismatch
      assert decision_metadata.reason == :none

      assert log =~ ~s(tenant_id: "#{tenant_id}")

      # No tenant logger metadata, as that may route it to the tenant's own logs. The message spans
      # several lines, metadata is on the first: the one with the code.
      header_lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "PolicyEvalShadowMismatch"))
      assert header_lines != []

      for line <- header_lines do
        refute line =~ "project="
        refute line =~ "external_id="
        refute line =~ "tenant_id="
      end
    end

    test "a real check that errored becomes :no_real_answer, not a crash or a mismatch" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)
      ctx = context(tenant_id: tenant_id)

      assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], {:error, :missing_partition})
      assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :no_real_answer
      assert decision_metadata.real == nil
      assert decision_metadata.reason == :none
    end

    test "Postgres raising on the policy is a real answer: decided against it is a mismatch, logged without the message" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)
      result = policy_error(:invalid_text_representation, "22P02", ~s(invalid input syntax for type uuid: "user_2abc"))

      log =
        capture_log(fn ->
          assert :ok = PolicyEvalShadow.read(:fake_conn, context(tenant_id: tenant_id), [:broadcast], result)
          assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
        end)

      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :mismatch
      assert decision_metadata.real == {:error, "22P02"}
      assert log =~ "PolicyEvalShadowMismatch"
      assert log =~ "22P02"
      refute log =~ "user_2abc"
    end

    test "an error that isn't from evaluating the policy stays :no_real_answer" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)
      result = policy_error(:admin_shutdown, "57P01", "terminating connection due to administrator command")

      assert :ok = PolicyEvalShadow.read(:fake_conn, context(tenant_id: tenant_id), [:broadcast], result)
      assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :no_real_answer
      assert decision_metadata.real == nil
    end

    test "a fallback against Postgres raising on the policy stays a fallback" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@read_decision)
      timing_ref = attach(@read_timing)
      ctx = context(tenant_id: tenant_id, role: "service_role", claims: %{"role" => "service_role"})
      result = policy_error(:invalid_text_representation, "22P02", "invalid input syntax for type uuid")

      assert :ok = PolicyEvalShadow.read(:fake_conn, ctx, [:broadcast], result)
      assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :fallback
      assert decision_metadata.real == {:error, "22P02"}
    end

    test "snapshot unavailable: records :unavailable, still emits timing, never raises" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:error, :boom} end)

      unavailable_ref = attach(@read_unavailable)
      timing_ref = attach(@read_timing)

      assert :ok = PolicyEvalShadow.read(:fake_conn, context(tenant_id: tenant_id), [:broadcast], {:ok, %Policies{}})

      assert_receive {:telemetry, ^unavailable_ref, _event, _measurements, %{tenant: ^tenant_id} = metadata}, 2000
      assert metadata.reason =~ "boom"
      assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
    end

    test "deciding raises: records :exception and logs the tenant id in the message, never the exception's message" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)
      expect(PolicyEvalEnv, :build, fn _context, _extension -> raise "policy content" end)

      exception_ref = attach(@read_exception)
      timing_ref = attach(@read_timing)

      log =
        capture_log(fn ->
          assert :ok =
                   PolicyEvalShadow.read(:fake_conn, context(tenant_id: tenant_id), [:broadcast], {:ok, %Policies{}})

          assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
        end)

      assert_received {:telemetry, ^exception_ref, _event, _measurements, %{tenant: ^tenant_id, extension: :broadcast}}
      assert log =~ "PolicyEvalShadowException"
      assert log =~ ~s(tenant_id: "#{tenant_id}")
      assert log =~ "RuntimeError"
      refute log =~ "policy content"

      header_lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "PolicyEvalShadowException"))
      assert header_lines != []

      for line <- header_lines do
        refute line =~ "project="
        refute line =~ "external_id="
        refute line =~ "tenant_id="
      end
    end
  end

  describe "write/4" do
    test ":persistence reads the real answer off policies.broadcast.persist" do
      tenant_id = unique_tenant_id()
      expect(FeatureFlags, :enabled?, fn @flag, _tenant_id -> true end)
      expect(PolicyEvalCache, :fetch, fn :fake_conn, _tenant_id -> {:ok, always_allow_snapshot()} end)

      decision_ref = attach(@write_decision)
      timing_ref = attach(@write_timing)

      ctx = context(tenant_id: tenant_id)
      result = {:ok, %Policies{broadcast: %BroadcastPolicies{persist: true}}}

      assert :ok = PolicyEvalShadow.write(:fake_conn, ctx, [:persistence], result)
      assert_receive {:telemetry, ^timing_ref, _event, _measurements, %{tenant: ^tenant_id}}, 2000
      assert_received {:telemetry, ^decision_ref, _event, _measurements, %{tenant: ^tenant_id} = decision_metadata}
      assert decision_metadata.outcome == :match
      assert decision_metadata.real == true
    end
  end

  describe "spliced into Authorization" do
    setup [:checkout_tenant_and_connect]

    test "the real result is identical whether the shadow flag is on or off", %{db_conn: db_conn, tenant: tenant} do
      Enum.each(PolicyEvalPolicies.user_channel_policies(:plain), &Postgrex.query!(db_conn, &1, []))

      ctx =
        Authorization.build_authorization_params(%{
          tenant_id: tenant.external_id,
          topic: "room:1",
          headers: [],
          claims: %{"role" => "authenticated"},
          role: "authenticated",
          sub: nil
        })

      flag_off = Authorization.get_read_authorizations(%Policies{}, db_conn, ctx)

      # Both get_read_authorizations/4 (via check_with_fallback) and the shadow hook check a flag —
      # only the shadow one is under test here, so the other keeps its natural (unset -> false) answer.
      expect(FeatureFlags, :enabled?, 2, fn
        "use_authorize_function", _tenant_id -> false
        @flag, _tenant_id -> true
      end)

      flag_on = Authorization.get_read_authorizations(%Policies{}, db_conn, ctx)

      assert flag_off == flag_on
    end
  end
end
