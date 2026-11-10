defmodule PolicyEval.Test.ExampleProfile do
  @moduledoc """
  The profile of the example that the tests use. The example is an application with documents in
  the table `app.docs`. A document belongs to a team (`team`) and has a kind (`kind`). Before a
  query, the application sets the session settings that its policies read, all with the prefix
  `app.`. `PolicyEval.Test.ExampleDatabase` creates the same example in a plain Postgres.

  The functions in the schema `app` read those settings:

    * `app.team()`: the team of the session, from `app.team`
    * `app.user_id()`: the id of the user, a uuid, from `app.user_id`
    * `app.user_role()`: the role of the user, from `app.user_role`
    * `app.claims()`: the claims of the user, a jsonb object, from `app.claims`

  `app.user_id()` and `app.user_role()` have two known bodies. The simple body reads only its
  setting. The fallback body reads `sub` or `role` from the claims when its setting is empty.
  """

  import PolicyEval.KnownFunction

  alias PolicyEval.Profile

  @spec profile() :: Profile.t()
  def profile do
    %Profile{
      write_plans_select: true,
      columns: %{"team" => :text, "kind" => :text},
      functions: functions(),
      roles: ["guest", "member"],
      policy_roles: ["guest", "member", "admin"],
      platform_roles: ["admin", "postgres"],
      platform_schemas: ["app"],
      platform_setting_prefixes: ["app."]
    }
  end

  @team "select nullif(current_setting('app.team', true), '')::text"
  @user_id_simple "select nullif(current_setting('app.user_id', true), '')::uuid"
  @user_role_simple "select nullif(current_setting('app.user_role', true), '')::text"
  @claims "select nullif(current_setting('app.claims', true), '')::jsonb"

  @user_id_fallback """
  select
    coalesce(
      nullif(current_setting('app.user_id', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  """

  @user_role_fallback """
  select
    coalesce(
      nullif(current_setting('app.user_role', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'role')
    )::text
  """

  defp functions do
    [
      new("app", "team", "text", @team, nullif_empty("app.team")),
      new("app", "user_id", "uuid", @user_id_simple, to_uuid(nullif_empty("app.user_id"))),
      new("app", "user_id", "uuid", @user_id_fallback, to_uuid(setting_or_claim("app.user_id", "sub"))),
      new("app", "user_role", "text", @user_role_simple, nullif_empty("app.user_role")),
      new("app", "user_role", "text", @user_role_fallback, setting_or_claim("app.user_role", "role")),
      new("app", "claims", "jsonb", @claims, to_jsonb(claims()))
    ]
  end

  # nullif(current_setting(name, true), '')
  defp nullif_empty(name), do: nullif(setting(name), text(""))

  defp claims, do: nullif_empty("app.claims")

  # coalesce(nullif(current_setting(setting, true), ''),
  #          (nullif(current_setting('app.claims', true), '')::jsonb ->> field))
  defp setting_or_claim(setting, field), do: coalesce([nullif_empty(setting), field_text(to_jsonb(claims()), field)])
end
