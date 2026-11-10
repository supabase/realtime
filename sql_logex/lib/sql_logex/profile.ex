defmodule SqlLogex.Profile do
  @moduledoc """
  What the library knows about the table it decides for, and about the platform around it. The
  rest of the library models Postgres only, so a profile is the one place for those choices.
  `SqlLogex.Snapshot.new/2` takes one, and the snapshot keeps it for `SqlLogex.decide/3`. The
  caller builds the profile. The library has none of its own.

  A profile holds:

    * `write_plans_select`: whether the caller plans a `SELECT` of the table in the same call as
      the `INSERT` of a write. Then a write also needs the `SELECT` grant, and it falls back
      where a `SELECT` policy might raise, see `SqlLogex.PolicySet`. The only value is `true`,
      because only that case is measured against Postgres
    * `columns`: the columns of the checked row that a policy can read, with their types
      (`SqlLogex.Resolver.type/0`). A policy that reads another column is unsupported
    * `functions`: the function definitions that can be inlined, built with
      `SqlLogex.KnownFunction`
    * `roles`: the roles `decide/3` decides for. Any other role falls back
    * `policy_roles`: the roles a policy can name, besides `public`. A policy for another role
      makes the decision fall back, because a policy applies by inherited role membership, which
      the library does not model. The library assumes that none of these roles is a member of
      another
    * `platform_roles`, `platform_schemas` and `platform_setting_prefixes`: names that the
      platform around the database defines, not the policy author, so a fallback reason can keep
      them. A reason holds `:other` or `:other_schema` in place of any other name. A
      zero-argument call to a function in a platform schema is also looked up in the snapshot's
      functions, and a call anywhere else is unsupported
  """

  @type t :: %__MODULE__{
          write_plans_select: true,
          columns: %{optional(String.t()) => SqlLogex.Resolver.type()},
          functions: [SqlLogex.KnownFunction.t()],
          roles: [String.t()],
          policy_roles: [String.t()],
          platform_roles: [String.t()],
          platform_schemas: [String.t()],
          platform_setting_prefixes: [String.t()]
        }

  @enforce_keys [
    :write_plans_select,
    :columns,
    :functions,
    :roles,
    :policy_roles,
    :platform_roles,
    :platform_schemas,
    :platform_setting_prefixes
  ]
  defstruct @enforce_keys
end
