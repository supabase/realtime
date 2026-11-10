defmodule SqlLogex.DifferentialTest do
  # SqlLogex.Differential: the answers, the classes and the failure message. The tests against
  # Postgres (test/postgres) use it with the answers of a database.
  use ExUnit.Case, async: true

  alias SqlLogex.Differential
  alias SqlLogex.Differential.VerificationError
  alias SqlLogex.Env
  alias SqlLogex.Snapshot
  alias SqlLogex.Test.ExampleProfile

  @raises_uuid {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}
  @postgres_uuid_error {:error, "22P02", :invalid_text_representation, ~s(invalid input syntax for type uuid: "x")}

  defp snapshot do
    policy = %{name: "p", cmd: "r", permissive: true, roles: ["public"], qual: "(team = 'x'::text)", with_check: nil}
    roles = %{"member" => %{bypass_rls: false, select: true, insert: true}}

    Snapshot.new(
      %{rls_enabled: true, rls_forced: false, roles: roles, policies: [policy], functions: []},
      ExampleProfile.profile()
    )
  end

  defp env(role, team),
    do: Env.new(%{"role" => role}, %{"team" => {:text, team}, "kind" => {:text, "note"}})

  test "decide/3 gives the decision as an answer" do
    assert Differential.decide(snapshot(), env("member", "x"), :read) == {:value, true}
    assert Differential.decide(snapshot(), env("member", "y"), :read) == {:value, false}
    assert Differential.decide(snapshot(), env("admin", "x"), :read) == {:unsupported, {:role, "admin"}}
  end

  test "compare/3 puts each pair of answers in a class" do
    class = fn postgres, library ->
      result = Differential.compare(postgres, library)
      {result.class, result.sub}
    end

    assert class.({:ok, true}, {:value, true}) == {:match, nil}
    assert class.({:ok, true}, {:value, false}) == {:mismatch, :postgres_value}
    assert class.(@postgres_uuid_error, {:value, false}) == {:mismatch, :postgres_error}
    assert class.({:ok, true}, {:unsupported, :regex_not_literal}) == {:fallback, :postgres_value}
    assert class.(@postgres_uuid_error, {:unsupported, @raises_uuid}) == {:fallback, :postgres_error_predicted}
    assert class.(@postgres_uuid_error, {:unsupported, :regex_not_literal}) == {:fallback, :postgres_error}
    assert class.({:ok, true}, {:crash, {:exception, ArgumentError}}) == {:crash, nil}

    division = {:error, "22012", :division_by_zero, "division by zero"}
    assert class.(division, {:unsupported, @raises_uuid}) == {:fallback, :postgres_error_other_sqlstate}
  end

  test "compare/3 keeps the fields that the caller gives" do
    result = Differential.compare({:ok, true}, {:value, true}, name: "n", group: :g, meta: %{role: "guest"})

    assert %{name: "n", group: :g, meta: %{role: "guest"}, postgres: {:ok, true}, library: {:value, true}} = result
    assert result.detail == ""
  end

  test "verify!/1 passes matches and fallbacks, and raises with each mismatch and crash" do
    match = Differential.compare({:ok, true}, {:value, true}, name: "a match")
    fallback = Differential.compare({:ok, true}, {:unsupported, :regex_not_literal}, name: "a fallback")
    mismatch = Differential.compare({:ok, true}, {:value, false}, name: "a mismatch", group: "g", detail: "  why\n")

    assert Differential.verify!([match, fallback]) == :ok

    error = assert_raise VerificationError, fn -> Differential.verify!([match, fallback, mismatch]) end

    assert error.failures == [mismatch]
    assert error.message =~ "1 of 3 comparisons fail (1 mismatch)."

    assert error.message =~
             "[g] a mismatch\n  mismatch (postgres_value)\n  postgres: returned true\n  library:  false\n  why"

    refute error.message =~ "a match"
  end

  test "report/2 counts the classes, the groups and the reasons of the fallbacks" do
    results = [
      Differential.compare({:ok, true}, {:value, true}, group: "g"),
      Differential.compare({:ok, false}, {:value, false}, group: "g"),
      Differential.compare(@postgres_uuid_error, {:unsupported, @raises_uuid}, group: "h")
    ]

    report = Differential.report(results, "Policies")

    assert report =~ "Policies: 3 cases"
    assert report =~ "match     2   (Postgres returned true 1, false 1, NULL 0)"
    assert report =~ "of which the library predicted 1"
    assert report =~ "    g: 2 (match 2)\n    h: 1 (fallback 1)"
    assert report =~ "1  raises invalid_text_representation"
  end
end
