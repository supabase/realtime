defmodule RealtimeWeb.Dashboard.TenantInfo.PolicyEvalTest do
  # Renders the Policies card from reports built on plain input, so no tenant database is needed.
  # Realtime.Tenants.PolicyEvalReportTest checks the reports, and TenantInfoTest reads a real one.
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Realtime.Tenants.PolicyEvalReport
  alias RealtimeWeb.Dashboard.TenantInfo.PolicyEval

  @topic_source "select nullif(current_setting('realtime.topic', true), '')::text;"
  @uid_source "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"

  @supported "(realtime.topic() = 'x'::text)"
  @builtin "((realtime.topic() = 'x'::text) AND (lower(extension) = 'y'::text))"
  @lower ~s|function: {:function, "lower", :not_allowlisted}|

  @granted %{bypass_rls: false, select: true, insert: true}

  test "shows each decision with the policies it evaluates and where it falls back" do
    html =
      render_report(%{
        policies: [
          policy("lobby", "r", ["public"], @supported),
          policy("builtin", "a", ["authenticated"], nil, @builtin)
        ]
      })

    assert text(html, "#policy-eval-section summary") == "Policies on realtime.messages (2)"

    assert cells(html, "policy-eval-decisions") == [
             ["anon", "read", "evaluates lobby no unsupported parts"],
             ["anon", "write", "always denied: no permissive policy applies"],
             ["authenticated", "read", "evaluates lobby no unsupported parts"],
             ["authenticated", "write", "evaluates builtin falls back when the evaluation reaches: #{@lower}"]
           ]
  end

  test "row level security that is forced or off makes every decision fall back, and shows in red" do
    policies = [policy("lobby", "*", ["public"], @supported)]

    forced = render_report(%{rls_forced: true, policies: policies})

    forced_outcome = "always falls back: row level security is forced on realtime.messages setup: :rls_forced"
    assert outcomes(forced) == List.duplicate(forced_outcome, 4)

    assert [["realtime.messages", "row level security enabled, forced"] | _] = cells(forced, "policy-eval-roles")
    assert texts(forced, "#policy-eval-roles .text-danger") == ["forced"]

    disabled = render_report(%{rls_enabled: false, policies: policies})

    assert [["realtime.messages", "row level security disabled, not forced"] | _] = cells(disabled, "policy-eval-roles")
    assert texts(disabled, "#policy-eval-roles .text-danger") == ["disabled"]
  end

  test "shows a missing grant, a role that bypasses RLS and a missing role in red" do
    html =
      render_report(%{
        roles: %{"anon" => %{@granted | insert: false}, "authenticated" => %{@granted | bypass_rls: true}}
      })

    assert [_table, ["anon", "no", "yes", "no"], ["authenticated", "yes", "yes", "yes"]] =
             cells(html, "policy-eval-roles")

    assert texts(html, "#policy-eval-roles .text-danger") == ["no", "yes"]

    missing = render_report(%{roles: %{"authenticated" => @granted}})

    assert [_table, ["anon", "does not exist"], ["authenticated", "no", "yes", "yes"]] =
             cells(missing, "policy-eval-roles")

    assert texts(missing, "#policy-eval-roles .text-danger") == ["does not exist"]
  end

  test "shows each policy with its expressions and what policy_eval cannot use in them" do
    html =
      render_report(%{
        policies: [
          policy("both", "*", ["anon", "authenticated"], @supported, @builtin, false),
          policy("edit", "w", ["postgres"], @supported),
          policy("admins", "r", ["postgres"], @supported)
        ]
      })

    assert cells(html, "policy-eval-policies") == [
             ["both", "ALL", "restrictive", "anon authenticated", "#{@supported} supported", "#{@builtin} #{@lower}"],
             ["edit", "UPDATE not used by Realtime", "permissive", "postgres", "#{@supported} supported", "none"],
             ["admins", "SELECT", "permissive", "postgres (not modelled)", "#{@supported} supported", "none"]
           ]

    assert texts(html, "#policy-eval-policies .text-danger") == [@lower, "postgres (not modelled)"]
  end

  test "a tenant without policies denies every decision" do
    html = render_report(%{})

    assert text(html, "#policy-eval-section summary") == "Policies on realtime.messages (0)"
    assert cells(html, "policy-eval-policies") == [["None"]]

    assert outcomes(html) == List.duplicate("always denied: no permissive policy applies", 4)
  end

  test "shows whether policy_eval can inline each known function, with its definitions" do
    html =
      render_report(%{
        functions: [
          function("realtime", "topic", "text", @topic_source),
          function("auth", "uid", "uuid", @uid_source, %{security_definer: true}),
          function("auth", "role", "text", "select 'a'::text"),
          function("auth", "role", "text", "select 'b'::text")
        ]
      })

    functions = Map.new(cells(html, "policy-eval-functions"), fn [name | cells] -> {name, cells} end)

    assert %{
             "realtime.topic()" => ["known", _],
             "auth.uid()" => ["unknown definition", uid],
             "auth.role()" => ["overloaded", role],
             "auth.jwt()" => ["not in snapshot", ""]
           } = functions

    assert uid ==
             "language sql, volatility s, security definer true, config nil, returns uuid #{@uid_source}"

    assert role =~ "select 'a'::text"
    assert role =~ "select 'b'::text"

    assert Enum.sort(texts(html, "#policy-eval-functions .text-danger")) ==
             ["not in snapshot", "overloaded", "unknown definition"]
  end

  defp render_report(overrides) do
    assigns = %{state: {:ok, PolicyEvalReport.build(input(overrides))}}

    ~H"""
    <PolicyEval.card state={@state} />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

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

  # The text of each cell of each body row. LazyHTML and the whitespace collapsing are those of
  # has_element?/3, so a cell reads the same as in TenantInfoTest.
  defp cells(html, table_id) do
    for row <- LazyHTML.query(html, "##{table_id} tbody tr") do
      row |> LazyHTML.query("td") |> Enum.map(&normalize(LazyHTML.text(&1)))
    end
  end

  defp outcomes(html), do: Enum.map(cells(html, "policy-eval-decisions"), &List.last/1)

  defp text(html, selector), do: html |> LazyHTML.query(selector) |> LazyHTML.text() |> normalize()
  defp texts(html, selector), do: html |> LazyHTML.query(selector) |> Enum.map(&normalize(LazyHTML.text(&1)))

  defp normalize(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
end
