defmodule SqlLogex.Test.RealtimeProfile do
  import SqlLogex.KnownFunction

  alias SqlLogex.Profile

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

  # `request.jwt.claim` (singular) is not one of the settings of the example, so in its sessions
  # current_setting returns NULL (never set) or '' (set earlier on that backend), and
  # nullif(..., '') turns both into NULL. This argument is therefore always NULL.
  defp claim_singular, do: null()

  # nullif(current_setting(name, true), '')
  defp nullif_empty(name), do: nullif(setting(name), text(""))

  defp claims, do: nullif_empty("request.jwt.claims")

  # coalesce(nullif(current_setting(setting, true), ''),
  #          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> field))
  defp claim_or_field(setting, field), do: coalesce([nullif_empty(setting), field_text(to_jsonb(claims()), field)])
end
