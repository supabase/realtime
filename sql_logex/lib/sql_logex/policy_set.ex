defmodule SqlLogex.PolicySet do
  @moduledoc """
  Decides whether a role may read or write a row, like Postgres does for `realtime.messages`.

  `decide/3` returns `:allow` or `:deny` when it is sure, and `{:fallback, reason}` when the
  database has to be asked. It is sure only when it models everything Postgres considers.

  ## Fallbacks before evaluating

  These are the things this library doesn't model, checked first, in this order:

    * the role (`env.settings["role"]`) is not `anon` or `authenticated`: `{:role, role}`, with
      `:other` for a role that isn't `service_role`, `postgres` or `supabase_admin`
    * RLS is off (`:rls_disabled`) or forced (`:rls_forced`), or the role isn't in the snapshot
      (`{:role_not_in_snapshot, role}`)
    * the role bypasses RLS (`{:bypass_rls, role}`) or lacks a privilege the operation needs
      (`{:missing_grant, role, :select | :insert}`): `select` for a read, `insert` and `select`
      for a write (see below)
    * a policy of the right command names a role other than `public`, `anon`, `authenticated` or
      `service_role` (`:unmodelled_policy_role`). Policies match by inherited role membership,
      which isn't modelled
    * for a write, a `SELECT` or `ALL` policy that might apply to the role has no `USING`
      expression, or one that isn't fully modelled: `:select_policy_unsupported`. Or it is
      unsupported for this input, raising included: `{:unsupported, reason}`. See below
    * an applicable policy lacks the expression to evaluate (`:policy_without_expression`)
    * the result is unsupported (`{:unsupported, reason}`)
    * anything raises (`{:exception, exception_module}`)

  Fallback reasons never contain policy text, policy or role names, names from the tenant's own
  schemas (functions, types, settings) or input values, so they can be logged and used as metric
  tags. Names in `auth` and `realtime`, and settings starting with `request.` or `realtime.`, are
  kept: those are Supabase's namespaces, even for a function a tenant created there.

  ## Which policies, which expressions

  Reads use the policies for `SELECT` (`"r"`) and `ALL` (`"*"`), writes those for `INSERT`
  (`"a"`) and `ALL`, and a policy applies if it names `public` or the role. A read evaluates the
  policy's `USING` expression. A write evaluates its `WITH CHECK`, or for an `ALL` policy
  without one the `USING` expression (`QUAL_FOR_WCO` in `rowsecurity.c`). An expression that
  isn't boolean is unsupported.

  ## Writes also depend on the read policies

  The write check of a join runs `realtime.authorize`
  (`lib/realtime/tenants/repo/migrations/20261002120000_add_authorize_function.ex` in Realtime),
  and that function plans and executes a `SELECT` of `realtime.messages` on every call, write-only
  calls included. With no probe rows to read, the statement runs nothing, but it is still planned:
  checking the `SELECT` privilege, expanding the `SELECT` policies and evaluating what the planner
  folds into constants. Measured against Postgres 17, a write-only call raised when the role lacked
  `SELECT` (42501), when a `SELECT` policy reads `realtime.messages` itself (42P17), and when a
  `SELECT` policy has a constant that raises, like `1 / 0` (22012), whatever the `INSERT` policies
  say. A `SELECT` policy that only raises when it is evaluated for a row, like the cast of a sub
  that isn't a uuid, did not fail a write-only call there, as there is no row to evaluate it for.
  Against a Multigres cluster it did, for `realtime.topic() = 't1' AND (SELECT auth.uid())::text =
  '...'`: whether the plan evaluates it anyway depends on more than the policy.

  So a write falls back where the function raises, even though only `INSERT` matters for
  the decision. This is conservative: it is not what the transaction path
  (`write_policies_with_transaction` and `check_write_policy` in
  `lib/realtime/tenants/authorization.ex`) does, which only inserts, so there a fallback may come
  where Postgres would decide. A write falls back with `{:missing_grant, role, :select}` if the
  role lacks `SELECT`, and with `:select_policy_unsupported` if a `SELECT` or `ALL` policy
  that might apply has no `USING` or has one with an unsupported node anywhere in it
  (`SqlLogex.IR.supported?/1`). That is decided from the tree alone: what the planner folds isn't
  modelled, so an expression we can't read is one that might fail. A policy we can read is then
  evaluated with the write's row, and falls back with `{:unsupported, reason}` if that is
  unsupported, raising included, as the plan might evaluate it. A policy that might apply is one
  for `public`, for the role, or for a role we don't model, as those apply by membership.

  ## Combining

  `final = OR(permissive policies) AND (each restrictive policy)`, with the evaluator's
  rules for unsupported parts (see `SqlLogex.Eval`). With no applicable permissive policy the
  result is `deny`, and nothing is evaluated: Postgres adds a constant `false` and doesn't look
  at the rest. Otherwise `true` allows, and `false` and NULL both deny.

  A write also checks one policy at a time in Postgres, restrictive ones first. Since each must
  be true that is the same as the `AND`, apart from which failure is reported.
  """

  alias SqlLogex.Env
  alias SqlLogex.Eval
  alias SqlLogex.IR
  alias SqlLogex.Policy
  alias SqlLogex.Snapshot

  @type reason :: term()
  @type decision :: :allow | :deny | {:fallback, reason}

  @modelled_roles ["public", "anon", "authenticated", "service_role"]

  # The roles that may show up in a reason, other names are the tenant's.
  @known_roles ["service_role", "postgres", "supabase_admin", nil]

  @doc "Decides for the role in `env`, see the module documentation."
  @spec decide(Snapshot.t(), Env.t(), :read | :write) :: decision
  def decide(snapshot, env, operation) when operation in [:read, :write] do
    run(snapshot, env, operation)
  rescue
    exception -> {:fallback, {:exception, exception.__struct__}}
  end

  defp run(%Snapshot{} = snapshot, %Env{} = env, operation) do
    role = Map.get(env.settings, "role")

    with :ok <- check_role(role),
         :ok <- check_snapshot(snapshot, role, operation),
         policies = Enum.filter(snapshot.policies, &(&1.cmd in commands(operation))),
         :ok <- check_policy_roles(policies),
         :ok <- check_select_policies(snapshot, env, role, operation),
         {permissive, restrictive} = policies |> Enum.filter(&applies_to?(&1, role)) |> Enum.split_with(& &1.permissive),
         {:ok, permissive} <- expressions(permissive, operation),
         {:ok, restrictive} <- expressions(restrictive, operation) do
      combine(permissive, restrictive, env)
    end
  end

  defp commands(:read), do: ["r", "*"]
  defp commands(:write), do: ["a", "*"]

  defp check_role(role) when role in ["anon", "authenticated"], do: :ok
  defp check_role(role) when role in @known_roles, do: {:fallback, {:role, role}}
  defp check_role(_role), do: {:fallback, {:role, :other}}

  # The privileges an operation needs. A write needs `select` too, see the moduledoc.
  defp grants(:read), do: [:select]
  defp grants(:write), do: [:insert, :select]

  # Anything but the expected boolean is treated as the unsafe answer.
  defp check_snapshot(snapshot, role, operation) do
    cond do
      snapshot.rls_enabled != true -> {:fallback, :rls_disabled}
      snapshot.rls_forced != false -> {:fallback, :rls_forced}
      not is_map_key(snapshot.roles, role) -> {:fallback, {:role_not_in_snapshot, role}}
      snapshot.roles[role][:bypass_rls] != false -> {:fallback, {:bypass_rls, role}}
      true -> check_grants(snapshot.roles[role], role, grants(operation))
    end
  end

  defp check_grants(privileges, role, grants) do
    case Enum.find(grants, &(privileges[&1] != true)) do
      nil -> :ok
      grant -> {:fallback, {:missing_grant, role, grant}}
    end
  end

  defp check_policy_roles(policies) do
    Enum.find_value(policies, :ok, fn policy ->
      case policy.roles -- @modelled_roles do
        [] -> nil
        [_ | _] -> {:fallback, :unmodelled_policy_role}
      end
    end)
  end

  defp applies_to?(%Policy{roles: roles}, role), do: "public" in roles or role in roles

  # A policy for a role we don't model applies by membership, so it might apply
  defp may_apply_to?(%Policy{roles: roles} = policy, role),
    do: applies_to?(policy, role) or roles -- @modelled_roles != []

  # The read statement of realtime.authorize, planned by every write. See the moduledoc.
  defp check_select_policies(_snapshot, _env, _role, :read), do: :ok

  defp check_select_policies(snapshot, env, role, :write) do
    snapshot.policies
    |> Enum.filter(&(&1.cmd in commands(:read) and may_apply_to?(&1, role)))
    |> Enum.find_value(:ok, &select_policy_fallback(&1.using, env))
  end

  # A SELECT policy we can't read might fail the statement. One we can read is evaluated with the
  # write's row: whether the plan evaluates it for a write-only call isn't modelled, so one that is
  # unsupported for this input, raising included, is a fallback too.
  defp select_policy_fallback(nil, _env), do: {:fallback, :select_policy_unsupported}

  defp select_policy_fallback({ir, type}, env) do
    if IR.supported?(ir) do
      case Eval.eval(boolean(ir, type), env) do
        {:unsupported, reason} -> {:fallback, {:unsupported, reason}}
        _result -> nil
      end
    else
      {:fallback, :select_policy_unsupported}
    end
  end

  # The IR to evaluate for each policy, or a fallback for the first one that has none.
  defp expressions(policies, operation), do: expressions(policies, operation, [])

  defp expressions([], _operation, irs), do: {:ok, Enum.reverse(irs)}

  defp expressions([policy | rest], operation, irs) do
    case expression(policy, operation) do
      nil -> {:fallback, :policy_without_expression}
      {ir, type} -> expressions(rest, operation, [boolean(ir, type) | irs])
    end
  end

  defp expression(policy, :read), do: policy.using
  defp expression(%Policy{cmd: "*", with_check: nil, using: using}, :write), do: using
  defp expression(policy, :write), do: policy.with_check

  defp boolean(ir, :bool), do: ir
  defp boolean({:unsupported, _} = unsupported, _type), do: unsupported
  defp boolean(_ir, type), do: {:unsupported, {:not_boolean, type}}

  # With no permissive policy Postgres uses a constant false and never evaluates the restrictive ones.
  defp combine([], _restrictive, _env), do: :deny

  defp combine(permissive, restrictive, env) do
    case Eval.eval({:and, [{:or, permissive} | restrictive]}, env) do
      true -> :allow
      result when result in [false, nil] -> :deny
      {:unsupported, reason} -> {:fallback, {:unsupported, reason}}
    end
  end
end
