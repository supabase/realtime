defmodule Realtime.Tenants.PolicyEvalReportTest do
  use ExUnit.Case, async: true

  alias Realtime.Tenants.PolicyEvalProfile
  alias Realtime.Tenants.PolicyEvalReport
  alias PolicyEval.Env
  alias PolicyEval.Snapshot

  @topic_source "select nullif(current_setting('realtime.topic', true), '')::text;"
  @uid_source "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"

  @supported "(realtime.topic() = 'x'::text)"
  @own_channel "(realtime.topic() = ('user:'::text || auth.uid()))"
  @builtin "((realtime.topic() = 'x'::text) AND (lower(extension) = 'y'::text))"

  @granted %{bypass_rls: false, select: true, insert: true}

  defp input(overrides) do
    Map.merge(
      %{
        rls_enabled: true,
        rls_forced: false,
        roles: %{"anon" => @granted, "authenticated" => @granted},
        policies: [],
        functions: [function("realtime", "topic", "text", @topic_source), function("auth", "uid", "uuid", @uid_source)]
      },
      overrides
    )
  end

  defp function(schema, name, return_type, source, overrides \\ %{}) do
    Map.merge(
      %{
        schema: schema,
        name: name,
        language: "sql",
        volatility: "s",
        security_definer: false,
        config: nil,
        return_type: return_type,
        source: source
      },
      overrides
    )
  end

  defp policy(name, cmd, roles, qual, with_check \\ nil, permissive \\ true) do
    %{name: name, cmd: cmd, permissive: permissive, roles: roles, qual: qual, with_check: with_check}
  end

  defp outcome(report, role, operation) do
    Enum.find_value(report.decisions, &(&1.role == role and &1.operation == operation and &1.outcome))
  end

  # Every "always" claim of the report, checked against PolicyEval.decide/3 for a few joins: a join to
  # the topic the policies name and one to another topic, with and without a sub.
  defp assert_matches_decide(input) do
    report = PolicyEvalReport.build(input)
    snapshot = Snapshot.new(input, PolicyEvalProfile.profile())

    for %{role: role, operation: operation, outcome: outcome} <- report.decisions,
        topic <- ["x", "user:00000000-0000-0000-0000-000000000001"],
        sub <- ["00000000-0000-0000-0000-000000000001", ""] do
      env = env(role, topic, sub)
      decision = PolicyEval.decide(snapshot, env, operation)

      case outcome do
        {:always_fallback, _} -> assert {:fallback, _} = decision, "#{role} #{operation} #{topic}"
        :no_permissive_policy -> assert decision == :deny, "#{role} #{operation} #{topic}"
        {:evaluates, _, _} -> :ok
      end
    end

    report
  end

  defp env(role, topic, sub) do
    claims = Jason.encode!(%{"role" => role, "sub" => sub})

    Env.new(
      %{
        "role" => role,
        "realtime.topic" => topic,
        "request.jwt.claims" => claims,
        "request.jwt.claim.sub" => sub,
        "request.jwt.claim.role" => role,
        "request.headers" => "{}"
      },
      %{"topic" => {:text, topic}, "extension" => {:text, "broadcast"}}
    )
  end

  describe "decisions" do
    test "a tenant whose policies are all supported evaluates them for every role" do
      report =
        assert_matches_decide(
          input(%{
            policies: [
              policy("lobby", "r", ["public"], @supported),
              policy("own channel", "a", ["authenticated"], nil, @own_channel)
            ]
          })
        )

      assert outcome(report, "anon", :read) == {:evaluates, ["lobby"], []}
      assert outcome(report, "authenticated", :read) == {:evaluates, ["lobby"], []}
      assert outcome(report, "authenticated", :write) == {:evaluates, ["own channel"], []}
      assert outcome(report, "anon", :write) == :no_permissive_policy
    end

    test "lists the unsupported parts of the policies a decision evaluates" do
      report = assert_matches_decide(input(%{policies: [policy("builtin", "*", ["authenticated"], @builtin)]}))

      unsupported = [{:function, {:function, "lower", :not_allowlisted}}]
      assert outcome(report, "authenticated", :read) == {:evaluates, ["builtin"], unsupported}
      assert outcome(report, "anon", :read) == :no_permissive_policy

      # The ALL policy has no WITH CHECK, so a write evaluates its USING.
      assert outcome(report, "authenticated", :write) == {:evaluates, ["builtin"], unsupported}
      assert outcome(report, "anon", :write) == :no_permissive_policy
    end

    test "every decision falls back when row level security is forced or off" do
      policies = [policy("lobby", "*", ["public"], @supported)]

      forced = assert_matches_decide(input(%{rls_forced: true, policies: policies}))
      assert Enum.all?(forced.decisions, &(&1.outcome == {:always_fallback, {:setup, :rls_forced}}))

      disabled = assert_matches_decide(input(%{rls_enabled: false, policies: policies}))
      assert Enum.all?(disabled.decisions, &(&1.outcome == {:always_fallback, {:setup, :rls_disabled}}))
    end

    test "a role without a grant, that bypasses RLS or does not exist falls back on every join" do
      report =
        assert_matches_decide(
          input(%{
            roles: %{"anon" => %{@granted | insert: false}, "authenticated" => %{@granted | bypass_rls: true}},
            policies: [policy("lobby", "*", ["public"], @supported)]
          })
        )

      assert outcome(report, "anon", :read) == {:evaluates, ["lobby"], []}
      assert outcome(report, "anon", :write) == {:always_fallback, {:setup, {:missing_grant, "anon", :insert}}}
      assert outcome(report, "authenticated", :read) == {:always_fallback, {:setup, {:bypass_rls, "authenticated"}}}

      missing = assert_matches_decide(input(%{roles: %{"authenticated" => @granted}}))

      assert outcome(missing, "anon", :read) == {:always_fallback, {:setup, {:role_not_in_snapshot, "anon"}}}
      assert [%{name: "anon", info: nil}, %{name: "authenticated", info: @granted}] = missing.roles
    end

    test "a policy for a role policy_eval does not model makes its command fall back" do
      report =
        assert_matches_decide(
          input(%{
            policies: [
              policy("admins", "r", ["postgres"], @supported),
              policy("lobby", "a", ["public"], nil, @supported)
            ]
          })
        )

      for role <- ["anon", "authenticated"] do
        assert outcome(report, role, :read) == {:always_fallback, {:setup, :unmodelled_policy_role}}
        assert outcome(report, role, :write) == {:evaluates, ["lobby"], []}
      end

      assert [%{name: "admins", unmodelled_roles: ["postgres"]}, %{name: "lobby", unmodelled_roles: []}] =
               report.policies
    end

    test "a SELECT policy with a subquery does not change a write" do
      exists = "(EXISTS ( SELECT 1\n   FROM realtime.messages m\n  WHERE (m.topic = 'x'::text)))"

      report =
        assert_matches_decide(
          input(%{
            policies: [
              policy("members", "r", ["authenticated"], exists),
              policy("send", "a", ["public"], nil, @supported)
            ]
          })
        )

      assert {:evaluates, ["members"], [{:subquery, {:unparsed, :exists}}]} = outcome(report, "authenticated", :read)

      for role <- ["anon", "authenticated"] do
        assert outcome(report, role, :write) == {:evaluates, ["send"], []}
      end
    end

    test "a policy without the expression a decision needs falls back" do
      report = assert_matches_decide(input(%{policies: [policy("no check", "a", ["anon"], nil, nil)]}))

      assert outcome(report, "anon", :write) == {:always_fallback, {:setup, :policy_without_expression}}
      assert outcome(report, "authenticated", :write) == :no_permissive_policy
    end
  end

  describe "policies" do
    test "holds the text, the command and the unsupported parts of each expression" do
      report =
        PolicyEvalReport.build(
          input(%{
            policies: [
              policy("both", "*", ["anon", "authenticated"], @supported, @builtin, false),
              policy("edit", "w", ["postgres"], @supported)
            ]
          })
        )

      assert [both, edit] = report.policies

      assert both == %{
               name: "both",
               command: "ALL",
               used: true,
               permissive: false,
               roles: ["anon", "authenticated"],
               unmodelled_roles: [],
               using: %{text: @supported, unsupported: []},
               with_check: %{text: @builtin, unsupported: [{:function, {:function, "lower", :not_allowlisted}}]}
             }

      # It names a role policy_eval does not model, but no decision checks an UPDATE policy.
      assert %{command: "UPDATE", used: false, roles: ["postgres"], unmodelled_roles: [], with_check: nil} = edit
    end
  end

  describe "functions" do
    test "tells whether each known function is one policy_eval can inline" do
      report =
        PolicyEvalReport.build(
          input(%{
            functions: [
              function("realtime", "topic", "text", @topic_source),
              function("auth", "uid", "uuid", @uid_source, %{security_definer: true}),
              function("auth", "role", "text", "select 'a'::text"),
              function("auth", "role", "text", "select 'b'::text")
            ]
          })
        )

      statuses = Map.new(report.functions, &{&1.name, &1.status})

      assert statuses == %{
               "realtime.topic" => :known,
               "auth.uid" => :unknown_definition,
               "auth.role" => :overloaded,
               "auth.jwt" => :not_in_snapshot
             }

      assert %{definitions: [%{source: @topic_source}]} = Enum.find(report.functions, &(&1.name == "realtime.topic"))
    end

    test "a call to a function policy_eval cannot inline is an unsupported part with the same why" do
      report =
        PolicyEvalReport.build(
          input(%{
            functions: [function("realtime", "topic", "text", @topic_source, %{volatility: "v"})],
            policies: [policy("lobby", "r", ["public"], @supported)]
          })
        )

      assert [%{name: "realtime.topic", status: :unknown_definition}, _, _, _] = report.functions

      assert outcome(report, "anon", :read) ==
               {:evaluates, ["lobby"], [{:function, {:function, "realtime.topic", :unknown_definition}}]}
    end
  end

  test "describe/1 explains every reason that can make a decision always fall back" do
    for reason <- [
          :rls_disabled,
          :rls_forced,
          {:role_not_in_snapshot, "anon"},
          {:bypass_rls, "anon"},
          {:missing_grant, "anon", :insert},
          :unmodelled_policy_role,
          :policy_without_expression
        ] do
      refute PolicyEvalReport.describe(reason) == inspect(reason)
    end

    assert PolicyEvalReport.describe({:missing_grant, "anon", :insert}) ==
             "anon does not have INSERT on realtime.messages"
  end
end
