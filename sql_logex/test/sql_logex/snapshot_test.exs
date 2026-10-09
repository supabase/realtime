defmodule SqlLogex.SnapshotTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Policy
  alias SqlLogex.Snapshot
  alias SqlLogex.Value

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @roles %{
    "anon" => %{bypass_rls: false, select: true, insert: false},
    "authenticated" => %{bypass_rls: false, select: true, insert: true}
  }

  defp attrs(policies, overrides \\ %{}) do
    Map.merge(
      %{rls_enabled: true, rls_forced: false, roles: @roles, policies: policies, functions: @functions},
      overrides
    )
  end

  describe "new/1" do
    test "keeps the table facts and the roles" do
      snapshot = Snapshot.new(attrs([], %{rls_enabled: false, rls_forced: true}))

      assert %Snapshot{rls_enabled: false, rls_forced: true, roles: @roles, policies: []} = snapshot
    end

    test "parses and resolves the expressions of every policy" do
      snapshot =
        Snapshot.new(
          attrs([
            %{
              name: "p",
              cmd: "r",
              permissive: true,
              roles: ["authenticated"],
              qual: "(realtime.topic() = 'x'::text)",
              with_check: nil
            },
            %{
              name: "q",
              cmd: "a",
              permissive: false,
              roles: ["public"],
              qual: nil,
              with_check: "(extension = 'broadcast'::text)"
            }
          ])
        )

      assert [
               %Policy{
                 name: "p",
                 cmd: "r",
                 permissive: true,
                 roles: ["authenticated"],
                 using: {{:apply, Value, :text_eq, [{:apply, Value, :nullif, _}, {:lit, {:text, "x"}}]}, :bool},
                 with_check: nil
               },
               %Policy{
                 name: "q",
                 cmd: "a",
                 permissive: false,
                 roles: ["public"],
                 using: nil,
                 with_check: {{:apply, Value, :text_eq, [{:column, "extension"}, {:lit, {:text, "broadcast"}}]}, :bool}
               }
             ] = snapshot.policies
    end

    test "an expression the parser or resolver can't handle is unsupported in place" do
      snapshot =
        Snapshot.new(
          attrs([
            %{name: "p", cmd: "r", permissive: true, roles: ["public"], qual: "CASE WHEN x THEN y END", with_check: nil}
          ])
        )

      assert [%Policy{using: {{:unsupported, {:unparsed, "CASE WHEN x THEN y END"}}, :unknown}}] = snapshot.policies
    end

    test "functions are optional, and without them calls are unsupported" do
      snapshot =
        Snapshot.new(%{
          rls_enabled: true,
          rls_forced: false,
          roles: @roles,
          policies: [
            %{
              name: "p",
              cmd: "r",
              permissive: true,
              roles: ["public"],
              qual: "(realtime.topic() = 'x'::text)",
              with_check: nil
            }
          ]
        })

      assert [%Policy{using: {{:unsupported, {:function, "realtime.topic", :not_in_snapshot}}, :unknown}}] =
               snapshot.policies
    end
  end
end
