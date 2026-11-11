defmodule PolicyEval.SnapshotTest do
  use ExUnit.Case, async: true

  alias PolicyEval.Policy
  alias PolicyEval.Snapshot
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Value

  @profile ExampleProfile.profile()

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @roles %{
    "guest" => %{bypass_rls: false, select: true, insert: false},
    "member" => %{bypass_rls: false, select: true, insert: true}
  }

  defp new_snapshot(attrs), do: Snapshot.new(attrs, @profile)

  defp attrs(policies, overrides \\ %{}) do
    Map.merge(
      %{rls_enabled: true, rls_forced: false, roles: @roles, policies: policies, functions: @functions},
      overrides
    )
  end

  describe "new/2" do
    test "keeps the table facts and the roles" do
      snapshot = new_snapshot(attrs([], %{rls_enabled: false, rls_forced: true}))

      assert %Snapshot{profile: @profile, rls_enabled: false, rls_forced: true, roles: @roles, policies: []} = snapshot
    end

    test "parses and resolves the expressions of every policy" do
      snapshot =
        new_snapshot(
          attrs([
            %{
              name: "p",
              cmd: "r",
              permissive: true,
              roles: ["member"],
              qual: "(app.team() = 'x'::text)",
              with_check: nil
            },
            %{
              name: "q",
              cmd: "a",
              permissive: false,
              roles: ["public"],
              qual: nil,
              with_check: "(kind = 'note'::text)"
            }
          ])
        )

      assert [
               %Policy{
                 name: "p",
                 cmd: "r",
                 permissive: true,
                 roles: ["member"],
                 using: {{:apply, Value, :text_eq, [{:apply, Value, :nullif, _}, {:lit, {:text, "x"}}]}, :bool},
                 with_check: nil
               },
               %Policy{
                 name: "q",
                 cmd: "a",
                 permissive: false,
                 roles: ["public"],
                 using: nil,
                 with_check: {{:apply, Value, :text_eq, [{:column, "kind"}, {:lit, {:text, "note"}}]}, :bool}
               }
             ] = snapshot.policies
    end

    test "an expression the parser or resolver can't handle is unsupported in place" do
      snapshot =
        new_snapshot(
          attrs([
            %{name: "p", cmd: "r", permissive: true, roles: ["public"], qual: "CASE WHEN x THEN y END", with_check: nil}
          ])
        )

      assert [%Policy{using: {{:unsupported, {:unparsed, :case}}, :unknown}}] = snapshot.policies
    end

    test "functions are optional, and without them calls are unsupported" do
      snapshot =
        new_snapshot(%{
          rls_enabled: true,
          rls_forced: false,
          roles: @roles,
          policies: [
            %{
              name: "p",
              cmd: "r",
              permissive: true,
              roles: ["public"],
              qual: "(app.team() = 'x'::text)",
              with_check: nil
            }
          ]
        })

      assert [%Policy{using: {{:unsupported, {:function, "app.team", :not_in_snapshot}}, :unknown}}] =
               snapshot.policies
    end
  end

  describe "unsupported/1" do
    defp policy(name, cmd, qual, opts \\ []) do
      %{
        name: name,
        cmd: cmd,
        permissive: Keyword.get(opts, :permissive, true),
        roles: ["public"],
        qual: qual,
        with_check: Keyword.get(opts, :with_check)
      }
    end

    test "is empty when every policy is modelled" do
      snapshot =
        new_snapshot(
          attrs([
            policy("p", "r", "(app.team() = 'x'::text)"),
            policy("q", "a", nil, with_check: "(kind = 'note'::text)")
          ])
        )

      assert Snapshot.unsupported(snapshot) == []
      assert [] |> attrs() |> new_snapshot() |> Snapshot.unsupported() == []
    end

    test "lists the cmd, permissive and reasons of the policies that aren't, without their names" do
      snapshot =
        new_snapshot(
          attrs([
            policy("modelled", "r", "(app.team() = 'x'::text)"),
            policy("secret_name", "r", "((app.team() = 'x'::text) AND (lower(kind) = 'y'::text))"),
            policy("other", "a", nil, with_check: "CASE WHEN x THEN y END", permissive: false),
            policy("custom", "*", "(public.my_fn() = 'x'::text)", with_check: "(app.email() = 'a'::text)")
          ])
        )

      assert Snapshot.unsupported(snapshot) == [
               %{cmd: "r", permissive: true, reasons: [{:function, "lower", :not_allowlisted}]},
               %{cmd: "a", permissive: false, reasons: [{:unparsed, :case}]},
               %{
                 cmd: "*",
                 permissive: true,
                 reasons: [{:function, :other_schema, :not_allowlisted}, {:function, "app.email", :not_in_snapshot}]
               }
             ]

      refute inspect(Snapshot.unsupported(snapshot)) =~ "secret_name"
    end

    test "has each reason of a policy once, over using and with_check" do
      snapshot =
        new_snapshot(
          attrs([
            policy("p", "*", "((lower(kind) = 'x'::text) OR (lower(kind) = 'y'::text))",
              with_check: "(lower(kind) = 'z'::text)"
            )
          ])
        )

      assert [%{reasons: [{:function, "lower", :not_allowlisted}]}] = Snapshot.unsupported(snapshot)
    end
  end
end
