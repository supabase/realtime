defmodule SqlLogex.Policy do
  @moduledoc """
  A row-level security policy with its expressions parsed and resolved.

  `using` and `with_check` are `{ir, type}` as `SqlLogex.Resolver` returns them, or `nil` when the
  policy has no such expression. `cmd` is the `pg_policy.polcmd` letter: `"r"` (SELECT), `"a"`
  (INSERT), `"w"` (UPDATE), `"d"` (DELETE) or `"*"` (ALL), and `roles` the names it applies to,
  with `"public"` for everyone.
  """

  @type expression :: {SqlLogex.IR.t(), SqlLogex.Resolver.type()}

  @type t :: %__MODULE__{
          name: String.t(),
          cmd: String.t(),
          permissive: boolean(),
          roles: [String.t()],
          using: expression | nil,
          with_check: expression | nil
        }

  defstruct [:name, :cmd, :permissive, :roles, :using, :with_check]
end

defmodule SqlLogex.Snapshot do
  @moduledoc """
  Everything `SqlLogex.PolicySet.decide/4` needs to know about a tenant's `realtime.messages`,
  as plain data: whether RLS is on, who may bypass it or lacks the grants, and the policies.

  `new/1` takes the data as the loader reads it from the catalog:

    * `rls_enabled` and `rls_forced`: `relrowsecurity` and `relforcerowsecurity` of the table
    * `roles`: for `"anon"` and `"authenticated"`, a map with `bypass_rls` (`rolbypassrls`) and the
      table privileges `select` and `insert`
    * `policies`: maps with `name`, `cmd`, `permissive`, `roles`, `qual` and `with_check`, where
      the last two are the text of `pg_get_expr` (or `nil`). The expressions must have been
      printed with `search_path = ''`, so every name is qualified
    * `functions`: maps with `schema`, `name`, `language`, `volatility`, `security_definer`,
      `config`, `return_type` and `source` for the zero-argument functions in the `realtime` and
      `auth` schemas (see `SqlLogex.Catalog`). Optional, `[]` by default. Two definitions with
      the same name, for instance overloads, make calls to it unsupported

  Every expression is parsed and resolved once, here, so deciding is only evaluation.
  """

  alias SqlLogex.Parser
  alias SqlLogex.Policy
  alias SqlLogex.Resolver

  @type role_info :: %{bypass_rls: boolean(), select: boolean(), insert: boolean()}

  @type t :: %__MODULE__{
          rls_enabled: boolean(),
          rls_forced: boolean(),
          roles: %{optional(String.t()) => role_info},
          policies: [Policy.t()]
        }

  defstruct [:rls_enabled, :rls_forced, :roles, :policies]

  @doc "Builds a snapshot, parsing and resolving the policy expressions."
  @spec new(map()) :: t
  def new(%{rls_enabled: rls_enabled, rls_forced: rls_forced, roles: roles, policies: policies} = attrs) do
    functions = Map.get(attrs, :functions, [])

    %__MODULE__{
      rls_enabled: rls_enabled,
      rls_forced: rls_forced,
      roles: roles,
      policies:
        Enum.map(policies, fn policy ->
          %Policy{
            name: policy.name,
            cmd: policy.cmd,
            permissive: policy.permissive,
            roles: policy.roles,
            using: expression(policy.qual, functions),
            with_check: expression(policy.with_check, functions)
          }
        end)
    }
  end

  defp expression(nil, _functions), do: nil
  defp expression(text, functions), do: text |> Parser.parse() |> Resolver.resolve(functions)
end
