defmodule PolicyEval.ProfileTest do
  # The profile is the only place where the library knows about the table and the platform. These
  # tests change one field of the example profile (PolicyEval.Test.ExampleProfile) and check that the
  # decision follows it. The answers for other profiles are not checked against Postgres: the tests
  # against Postgres (test/postgres) cover the example profile only.
  use ExUnit.Case, async: true

  alias PolicyEval.Env
  alias PolicyEval.Profile
  alias PolicyEval.Snapshot
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Value

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @example ExampleProfile.profile()
  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @roles %{
    "guest" => %{bypass_rls: false, select: true, insert: true},
    "member" => %{bypass_rls: false, select: true, insert: true}
  }

  defp snapshot(qual, profile) do
    policy = %{name: "p", cmd: "r", permissive: true, roles: ["public"], qual: qual, with_check: nil}

    Snapshot.new(
      %{rls_enabled: true, rls_forced: false, roles: @roles, policies: [policy], functions: @functions},
      profile
    )
  end

  defp env(role, row) do
    Env.new(%{"role" => role, "app.user_id" => @uid, "app.user_role" => role}, row)
  end

  test "the example profile has the columns and roles of app.docs" do
    assert @example.write_plans_select == true
    assert @example.columns == %{"team" => :text, "kind" => :text}
    assert @example.roles == ["guest", "member"]
  end

  test "a policy can read the columns of the profile, with their types" do
    owner_policy = "(owner = app.user_id())"
    owned_by = fn uid -> %{"owner" => Value.uuid_in({:text, uid})} end

    assert PolicyEval.decide(snapshot(owner_policy, @example), env("member", owned_by.(@uid)), :read) ==
             {:fallback, {:unsupported, {:column, "owner"}}}

    profile = %Profile{@example | columns: %{"owner" => :uuid}}

    assert PolicyEval.decide(snapshot(owner_policy, profile), env("member", owned_by.(@uid)), :read) == :allow
    assert PolicyEval.decide(snapshot(owner_policy, profile), env("member", owned_by.(@other_uid)), :read) == :deny
  end

  test "decide/3 decides only for the roles of the profile" do
    profile = %Profile{@example | roles: ["member"]}
    row = %{"team" => {:text, "t"}, "kind" => {:text, "note"}}

    assert PolicyEval.decide(snapshot("true", @example), env("guest", row), :read) == :allow
    assert PolicyEval.decide(snapshot("true", profile), env("guest", row), :read) == {:fallback, {:role, :other}}
  end

  test "reported_role/2 keeps the profile's roles, platform roles and a missing role, nothing else" do
    assert Profile.reported_role(@example, "member") == "member"
    assert Profile.reported_role(@example, "admin") == "admin"
    assert Profile.reported_role(@example, "postgres") == "postgres"
    assert Profile.reported_role(@example, nil) == nil
    assert Profile.reported_role(@example, "app_writer") == :other
    assert Profile.reported_role(@example, "dave") == :other
  end

  test "only a function in a platform schema of the profile is inlined, and only its name is kept" do
    row = %{"team" => {:text, "t"}, "kind" => {:text, "note"}}
    user_id_policy = "(app.user_id() = '#{@uid}'::uuid)"

    assert PolicyEval.decide(snapshot(user_id_policy, @example), env("member", row), :read) == :allow

    profile = %Profile{@example | platform_schemas: ["other"]}

    assert PolicyEval.decide(snapshot(user_id_policy, profile), env("member", row), :read) ==
             {:fallback, {:unsupported, {:function, :other_schema, :not_allowlisted}}}
  end
end
