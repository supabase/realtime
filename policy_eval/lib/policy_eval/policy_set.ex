defmodule PolicyEval.PolicySet do
  @moduledoc """
  Decides whether a role may read or write a row, like Postgres does for the table of the
  snapshot's profile (`PolicyEval.Profile`).

  `decide/3` returns `:allow` or `:deny` when it is sure, and `{:fallback, reason}` when the
  database has to be asked. It is sure only when it models everything Postgres considers.

  ## Fallbacks before evaluating

  These are the things this library doesn't model, checked first, in this order:

    * the role (`env.settings["role"]`) is not one of the profile's `roles`: `{:role, role}`,
      with `:other` for a role that isn't a platform role
    * RLS is off (`:rls_disabled`) or forced (`:rls_forced`), or the role isn't in the snapshot
      (`{:role_not_in_snapshot, role}`)
    * the role bypasses RLS (`{:bypass_rls, role}`) or lacks a privilege the operation needs
      (`{:missing_grant, role, :select | :insert}`): `select` for a read, `insert` for a write
    * a policy of the right command names a role other than `public` and the profile's
      `policy_roles` (`:unmodelled_policy_role`). Policies match by inherited role membership,
      which isn't modelled
    * an applicable policy lacks the expression to evaluate (`:policy_without_expression`)
    * the result is unsupported (`{:unsupported, reason}`)
    * anything raises (`{:exception, exception_module}`)

  Fallback reasons never contain policy text, policy or role names, other names that the policy
  author chose (functions, types, settings) or input values, so they can be logged and used as
  metric tags. The platform names of the profile are kept, even for a function that the policy
  author created in a platform schema.

  ## Which policies, which expressions

  Reads use the policies for `SELECT` (`"r"`) and `ALL` (`"*"`), writes those for `INSERT`
  (`"a"`) and `ALL`, and a policy applies if it names `public` or the role. A read evaluates the
  policy's `USING` expression. A write evaluates its `WITH CHECK`, or for an `ALL` policy
  without one the `USING` expression (`QUAL_FOR_WCO` in `rowsecurity.c`). An expression that
  isn't boolean is unsupported.

  ## Writes depend only on the INSERT policies

  A write is a plain `INSERT` of the row, with no `RETURNING`. It needs the `INSERT` privilege,
  and only the `INSERT` and `ALL` policies decide it. The `SELECT` privilege and the `SELECT`
  policies do not change the answer.

  The caller must not run other statements on the table as the role in the same call as the
  write. For example, Postgres plans the `SELECT` policies for a `SELECT` of the table even when it
  reads no rows. A policy that raises when planned then fails the call, whatever the `INSERT`
  policies say. Measured against Postgres 17, that happened when the role lacked `SELECT` (42501),
  when a `SELECT` policy reads the table itself (42P17), and when a `SELECT` policy has a constant
  that raises, like `1 / 0` (22012). `INSERT ... RETURNING` is not modelled either: it checks the
  `SELECT` policies against the new row, so a false one fails the insert.

  ## Combining

  `final = OR(permissive policies) AND (each restrictive policy)`, with the evaluator's
  rules for unsupported parts (see `PolicyEval.Eval`). With no applicable permissive policy the
  result is `deny`, and nothing is evaluated: Postgres adds a constant `false` and doesn't look
  at the rest. Otherwise `true` allows, and `false` and NULL both deny.

  A write also checks one policy at a time in Postgres, restrictive ones first. Since each must
  be true that is the same as the `AND`, apart from which failure is reported.
  """

  alias PolicyEval.Env
  alias PolicyEval.Eval
  alias PolicyEval.Policy
  alias PolicyEval.Profile
  alias PolicyEval.Snapshot

  @type reason :: term()
  @type decision :: :allow | :deny | {:fallback, reason}

  @doc "Decides for the role in `env`, see the module documentation."
  @spec decide(Snapshot.t(), Env.t(), :read | :write) :: decision
  def decide(snapshot, env, operation) when operation in [:read, :write] do
    run(snapshot, env, operation)
  rescue
    exception -> {:fallback, {:exception, exception.__struct__}}
  end

  defp run(%Snapshot{profile: %Profile{} = profile} = snapshot, %Env{} = env, operation) do
    role = Map.get(env.settings, "role")

    with :ok <- check_role(role, profile),
         :ok <- check_snapshot(snapshot, role, operation),
         policies = Enum.filter(snapshot.policies, &(&1.cmd in commands(operation))),
         :ok <- check_policy_roles(policies, profile),
         {permissive, restrictive} = policies |> Enum.filter(&applies_to?(&1, role)) |> Enum.split_with(& &1.permissive),
         {:ok, permissive} <- expressions(permissive, operation),
         {:ok, restrictive} <- expressions(restrictive, operation) do
      combine(permissive, restrictive, env, profile)
    end
  end

  defp commands(:read), do: ["r", "*"]
  defp commands(:write), do: ["a", "*"]

  # A reason names a role only if it is a platform one (or there is none), see
  # `Profile.reported_role/2`. Any other name is the policy author's choice.
  defp check_role(role, profile) do
    if role in profile.roles, do: :ok, else: {:fallback, {:role, Profile.reported_role(profile, role)}}
  end

  # The privileges an operation needs. A write is a plain INSERT, see the moduledoc.
  defp grants(:read), do: [:select]
  defp grants(:write), do: [:insert]

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

  defp check_policy_roles(policies, profile) do
    Enum.find_value(policies, :ok, fn policy ->
      case policy.roles -- modelled_roles(profile) do
        [] -> nil
        [_ | _] -> {:fallback, :unmodelled_policy_role}
      end
    end)
  end

  defp modelled_roles(profile), do: ["public" | profile.policy_roles]

  defp applies_to?(%Policy{roles: roles}, role), do: "public" in roles or role in roles

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
  defp combine([], _restrictive, _env, _profile), do: :deny

  defp combine(permissive, restrictive, env, profile) do
    case Eval.eval({:and, [{:or, permissive} | restrictive]}, env) do
      true -> :allow
      result when result in [false, nil] -> :deny
      {:unsupported, reason} -> {:fallback, {:unsupported, platform_reason(reason, profile)}}
    end
  end

  # Evaluation keeps the name of a setting that the env lacks (`PolicyEval.Value.current_setting/2`).
  # The name is the policy author's choice unless it is a platform one, and the reason gets logged.
  defp platform_reason({:unknown_setting, name}, profile) do
    if String.starts_with?(name, profile.platform_setting_prefixes),
      do: {:unknown_setting, name},
      else: {:unknown_setting, :other}
  end

  defp platform_reason(reason, _profile), do: reason
end
