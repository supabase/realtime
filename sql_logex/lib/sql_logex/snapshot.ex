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

  alias SqlLogex.IR
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

  @doc """
  The parts of the policies that aren't modelled: for each policy with an unsupported node in its
  `using` or `with_check`, its `cmd`, whether it is `permissive` and the reasons
  (`SqlLogex.IR.unsupported_reasons/1`). Policies without any are left out. There is no policy
  name in it, so like the reasons it can be logged.
  """
  @spec unsupported(t) :: [%{cmd: String.t(), permissive: boolean(), reasons: [term()]}]
  def unsupported(%__MODULE__{policies: policies}) do
    for policy <- policies, reasons = reasons(policy), reasons != [] do
      %{cmd: policy.cmd, permissive: policy.permissive, reasons: reasons}
    end
  end

  defp reasons(%Policy{using: using, with_check: with_check}) do
    for {ir, _type} <- [using, with_check], reason <- IR.unsupported_reasons(ir), uniq: true, do: reason
  end

  defp expression(nil, _functions), do: nil
  defp expression(text, functions), do: text |> Parser.parse() |> Resolver.resolve(functions)
end
