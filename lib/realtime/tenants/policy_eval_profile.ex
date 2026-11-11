defmodule Realtime.Tenants.PolicyEvalProfile do
  @moduledoc """
  The `PolicyEval.Profile` for `realtime.messages`: what policy_eval needs to know to decide a join
  to a private channel the way `realtime.authorize` does.

  `realtime.authorize` runs a `SELECT` and an `INSERT` of probe rows of `realtime.messages`.
  It plans the `SELECT` on every call, write-only calls included, so the profile sets `write_plans_select`.
  That makes a write fall back where the `SELECT` might raise, see `PolicyEval.PolicySet`. This is conservative: the
  transaction path (`write_policies_with_transaction` and `check_write_policy` in
  `Realtime.Tenants.Authorization`) only inserts, so there a fallback can come where Postgres
  decides.

  Before the call, Realtime sets exactly six settings in the session (in
  `Realtime.Tenants.Authorization`), always with the exact strings that `PolicyEval.Env` gets:

    * `role`
    * `realtime.topic`
    * `request.jwt.claims`
    * `request.jwt.claim.sub`
    * `request.jwt.claim.role`
    * `request.headers`

  A probe row has the columns `topic` and `extension`, both text. The decided roles are `anon` and
  `authenticated`, and a policy can also name `service_role`.

  The known functions are `realtime.topic()`, with the body that Realtime installs, and
  `auth.uid()`, `auth.role()` and `auth.jwt()`. Those three are Supabase's, not only Realtime's:
  the supabase/postgres image installs one version, and supabase/auth migrations install another.
  The older supabase/auth versions of `auth.uid()` (migrations 20211124214934 and 20211202183645)
  are not known: a body we don't know is never assumed to behave like one we do.

  The platform names are the `auth` and `realtime` schemas, the settings that start with
  `request.` or `realtime.`, and the roles `service_role`, `postgres` and `supabase_admin`.
  """

  import PolicyEval.KnownFunction

  alias PolicyEval.Profile

  @doc "The profile for `realtime.messages`."
  @spec profile() :: Profile.t()
  def profile do
    %Profile{
      write_plans_select: true,
      columns: %{"topic" => :text, "extension" => :text},
      functions: realtime_functions() ++ auth_functions(),
      roles: ["anon", "authenticated"],
      policy_roles: ["anon", "authenticated", "service_role"],
      platform_roles: ["service_role", "postgres", "supabase_admin"],
      platform_schemas: ["auth", "realtime"],
      platform_setting_prefixes: ["request.", "realtime."]
    }
  end

  @topic "select nullif(current_setting('realtime.topic', true), '')::text;"

  # The versions in the supabase/postgres image.
  @uid_legacy "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"
  @role_legacy "select nullif(current_setting('request.jwt.claim.role', true), '')::text;"

  # supabase/auth migration 20220224000811, which production projects run.
  @uid_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
  """

  @role_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
  """

  # supabase/auth migration 20220531120530.
  @jwt_supabase_auth """
  select
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
  """

  defp realtime_functions do
    [new("realtime", "topic", "text", @topic, nullif_empty("realtime.topic"))]
  end

  defp auth_functions do
    [
      new("auth", "uid", "uuid", @uid_legacy, to_uuid(nullif_empty("request.jwt.claim.sub"))),
      new("auth", "uid", "uuid", @uid_supabase_auth, to_uuid(claim_or_field("request.jwt.claim.sub", "sub"))),
      new("auth", "role", "text", @role_legacy, nullif_empty("request.jwt.claim.role")),
      new("auth", "role", "text", @role_supabase_auth, claim_or_field("request.jwt.claim.role", "role")),
      new("auth", "jwt", "jsonb", @jwt_supabase_auth, to_jsonb(coalesce([claim_singular(), claims()])))
    ]
  end

  # `request.jwt.claim` (singular) is not one of the settings Realtime sets, so on its connections
  # current_setting returns NULL (never set) or '' (set earlier on that backend), and
  # nullif(..., '') turns both into NULL. This argument is therefore always NULL.
  defp claim_singular, do: null()

  # nullif(current_setting(name, true), '')
  defp nullif_empty(name), do: nullif(setting(name), text(""))

  defp claims, do: nullif_empty("request.jwt.claims")

  # coalesce(nullif(current_setting(setting, true), ''),
  #          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> field))
  #
  # Both arguments count, see `PolicyEval.Value.coalesce/1`: claims that don't parse make it unsupported
  # even when the setting is set.
  defp claim_or_field(setting, field), do: coalesce([nullif_empty(setting), field_text(to_jsonb(claims()), field)])
end
