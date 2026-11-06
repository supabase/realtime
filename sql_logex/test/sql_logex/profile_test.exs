defmodule SqlLogex.ProfileTest do
  # The profile is the only place where the library knows about the table and the platform. These
  # tests change one field of the Realtime profile (the copy in test/support) and check that the
  # decision follows it. The answers for other profiles are not checked against Postgres: the
  # differential test in Realtime covers the Realtime profile only.
  use ExUnit.Case, async: true

  alias SqlLogex.Env
  alias SqlLogex.Profile
  alias SqlLogex.Snapshot
  alias SqlLogex.Test.RealtimeProfile
  alias SqlLogex.Value

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @realtime RealtimeProfile.profile()
  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @roles %{
    "anon" => %{bypass_rls: false, select: true, insert: true},
    "authenticated" => %{bypass_rls: false, select: true, insert: true}
  }

  defp snapshot(qual, profile) do
    policy = %{name: "p", cmd: "r", permissive: true, roles: ["public"], qual: qual, with_check: nil}

    Snapshot.new(
      %{rls_enabled: true, rls_forced: false, roles: @roles, policies: [policy], functions: @functions},
      profile
    )
  end

  defp env(role, row) do
    Env.new(%{"role" => role, "request.jwt.claim.sub" => @uid, "request.jwt.claim.role" => role}, row)
  end

  test "the Realtime profile has the columns and roles of realtime.messages" do
    assert @realtime.write_plans_select == true
    assert @realtime.columns == %{"topic" => :text, "extension" => :text}
    assert @realtime.roles == ["anon", "authenticated"]
  end

  test "a policy can read the columns of the profile, with their types" do
    owner_policy = "(owner = auth.uid())"
    owned_by = fn uid -> %{"owner" => Value.uuid_in({:text, uid})} end

    assert SqlLogex.decide(snapshot(owner_policy, @realtime), env("authenticated", owned_by.(@uid)), :read) ==
             {:fallback, {:unsupported, {:column, "owner"}}}

    profile = %Profile{@realtime | columns: %{"owner" => :uuid}}

    assert SqlLogex.decide(snapshot(owner_policy, profile), env("authenticated", owned_by.(@uid)), :read) == :allow
    assert SqlLogex.decide(snapshot(owner_policy, profile), env("authenticated", owned_by.(@other_uid)), :read) == :deny
  end

  test "decide/3 decides only for the roles of the profile" do
    profile = %Profile{@realtime | roles: ["authenticated"]}
    row = %{"topic" => {:text, "t"}, "extension" => {:text, "broadcast"}}

    assert SqlLogex.decide(snapshot("true", @realtime), env("anon", row), :read) == :allow
    assert SqlLogex.decide(snapshot("true", profile), env("anon", row), :read) == {:fallback, {:role, :other}}
  end

  test "only a function in a platform schema of the profile is inlined, and only its name is kept" do
    row = %{"topic" => {:text, "t"}, "extension" => {:text, "broadcast"}}
    uid_policy = "(auth.uid() = '#{@uid}'::uuid)"

    assert SqlLogex.decide(snapshot(uid_policy, @realtime), env("authenticated", row), :read) == :allow

    profile = %Profile{@realtime | platform_schemas: ["realtime"]}

    assert SqlLogex.decide(snapshot(uid_policy, profile), env("authenticated", row), :read) ==
             {:fallback, {:unsupported, {:function, :other_schema, :not_allowlisted}}}
  end
end
