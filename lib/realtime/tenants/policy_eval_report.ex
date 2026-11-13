defmodule Realtime.Tenants.PolicyEvalReport do
  @moduledoc """
  Explains what policy_eval makes of a tenant's policies on `realtime.messages`.
  It answers why shadow mode falls back for a tenant.

  `build/1` takes the map that `Realtime.Tenants.PolicyEvalLoader.read/1` returns, builds the snapshot
  with the profile that shadow mode uses (`Realtime.Tenants.PolicyEvalProfile`), and returns plain data:

    * `decisions`: for each role that policy_eval decides for and each operation, what happens whatever
      the join is (see `t:outcome/0`)
    * `rls_enabled`, `rls_forced` and `roles`: the state of the table and of the roles, which
      `PolicyEval.PolicySet` checks before any policy
    * `functions`: for each known function of the profile, whether policy_eval can inline the
      definition in the database
    * `policies`: each policy with its text and the unsupported parts of each expression, whether
      Realtime uses its command, and the roles it names that make decisions fall back

  An unsupported part is a `{category, reason}` pair. The category is the `reason` tag of the
  shadow-mode metrics (`PolicyEval.Reason.category/1`) and the reason is the detailed term. Unlike the
  shadow-mode logs, the report holds policy names and SQL text, so it is only for the dashboard.
  """

  alias Realtime.Tenants.PolicyEvalProfile
  alias PolicyEval.Catalog
  alias PolicyEval.IR
  alias PolicyEval.Policy
  alias PolicyEval.Profile
  alias PolicyEval.Reason
  alias PolicyEval.Snapshot

  @type unsupported :: {Reason.category(), term()}

  @typedoc """
  What `PolicyEval.decide/3` does for a role and an operation:

    * `{:always_fallback, {category, reason}}`: a check before any policy fails, so every join falls
      back. The reason is the first one that `PolicyEval.PolicySet` checks
    * `:no_permissive_policy`: no permissive policy applies, so every join is denied and no
      policy is evaluated
    * `{:evaluates, policy_names, unsupported}`: the decision evaluates these policies. A join falls
      back when the evaluation reaches one of the unsupported parts, or when Postgres raises on the
      input
  """
  @type outcome ::
          {:always_fallback, unsupported} | :no_permissive_policy | {:evaluates, [String.t()], [unsupported]}

  @type expression :: %{text: String.t(), unsupported: [unsupported]}

  @type t :: %{
          rls_enabled: boolean(),
          rls_forced: boolean(),
          roles: [%{name: String.t(), info: Snapshot.role_info() | nil}],
          decisions: [%{role: String.t(), operation: :read | :write, outcome: outcome}],
          functions: [%{name: String.t(), status: atom(), definitions: [map()]}],
          policies: [
            %{
              name: String.t(),
              command: String.t(),
              used: boolean(),
              permissive: boolean(),
              roles: [String.t()],
              unmodelled_roles: [String.t()],
              using: expression | nil,
              with_check: expression | nil
            }
          ]
        }

  @commands %{"r" => "SELECT", "a" => "INSERT", "w" => "UPDATE", "d" => "DELETE", "*" => "ALL"}

  @doc "Builds the report from the map that `Realtime.Tenants.PolicyEvalLoader.read/1` returns."
  @spec build(map()) :: t
  def build(input) do
    profile = PolicyEvalProfile.profile()
    snapshot = Snapshot.new(input, profile)

    %{
      rls_enabled: snapshot.rls_enabled,
      rls_forced: snapshot.rls_forced,
      roles: for(role <- profile.roles, do: %{name: role, info: Map.get(snapshot.roles, role)}),
      decisions:
        for(
          role <- profile.roles,
          operation <- [:read, :write],
          do: %{role: role, operation: operation, outcome: outcome(snapshot, role, operation)}
        ),
      functions: functions(Map.get(input, :functions, []), profile),
      # Snapshot.new/2 keeps the order of the policies, so each parsed policy lines up with its text.
      policies: Enum.zip_with(input.policies, snapshot.policies, &policy(&1, &2, profile))
    }
  end

  @doc "A sentence for the reason of an `{:always_fallback, {category, reason}}` outcome."
  @spec describe(term()) :: String.t()
  def describe(:rls_disabled), do: "row level security is off on realtime.messages"
  def describe(:rls_forced), do: "row level security is forced on realtime.messages"
  def describe({:role_not_in_snapshot, role}), do: "the role #{role} does not exist"
  def describe({:bypass_rls, role}), do: "#{role} bypasses row level security"

  def describe({:missing_grant, role, grant}),
    do: "#{role} does not have #{grant |> Atom.to_string() |> String.upcase()} on realtime.messages"

  def describe(:unmodelled_policy_role) do
    roles = Enum.join(["public" | PolicyEvalProfile.profile().policy_roles], ", ")
    "a policy for this command names a role that is not one of #{roles}"
  end

  def describe(:policy_without_expression), do: "a policy that applies has no expression for this command"
  def describe(reason), do: inspect(reason)

  ## Decisions

  # The checks before evaluating, in the order of `PolicyEval.PolicySet`, see "Fallbacks before
  # evaluating" in its moduledoc. None of them reads the env other than the role. So unlike
  # `PolicyEval.decide/3`, which needs a join, this can say what happens for every join.
  defp outcome(snapshot, role, operation) do
    policies = Enum.filter(snapshot.policies, &(&1.cmd in commands(operation)))
    applicable = Enum.filter(policies, &applies_to?(&1, role))

    with :ok <- check_table(snapshot),
         :ok <- check_role(snapshot, role, operation),
         :ok <- check_policy_roles(policies, snapshot.profile),
         {:ok, expressions} <- expressions(applicable, operation) do
      if Enum.any?(applicable, & &1.permissive) do
        unsupported = expressions |> Enum.flat_map(&unsupported/1) |> Enum.uniq()
        {:evaluates, Enum.map(applicable, & &1.name), unsupported}
      else
        :no_permissive_policy
      end
    else
      {:fallback, reason} -> {:always_fallback, {Reason.category(reason), reason}}
    end
  end

  defp commands(:read), do: ["r", "*"]
  defp commands(:write), do: ["a", "*"]

  # A write is a plain INSERT, see "Writes depend only on the INSERT policies" in
  # `PolicyEval.PolicySet`.
  defp grants(:read), do: [:select]
  defp grants(:write), do: [:insert]

  defp check_table(%Snapshot{rls_enabled: true, rls_forced: false}), do: :ok
  defp check_table(%Snapshot{rls_enabled: enabled}) when enabled != true, do: {:fallback, :rls_disabled}
  defp check_table(_snapshot), do: {:fallback, :rls_forced}

  defp check_role(snapshot, role, operation) do
    case Map.fetch(snapshot.roles, role) do
      :error ->
        {:fallback, {:role_not_in_snapshot, role}}

      {:ok, %{bypass_rls: false} = info} ->
        case Enum.find(grants(operation), &(info[&1] != true)) do
          nil -> :ok
          grant -> {:fallback, {:missing_grant, role, grant}}
        end

      {:ok, _info} ->
        {:fallback, {:bypass_rls, role}}
    end
  end

  defp check_policy_roles(policies, profile) do
    if Enum.any?(policies, &(unmodelled_roles(&1, profile) != [])),
      do: {:fallback, :unmodelled_policy_role},
      else: :ok
  end

  defp expressions(policies, operation) do
    expressions = Enum.map(policies, &expression(&1, operation))
    if nil in expressions, do: {:fallback, :policy_without_expression}, else: {:ok, expressions}
  end

  defp expression(policy, :read), do: policy.using
  defp expression(%Policy{cmd: "*", with_check: nil, using: using}, :write), do: using
  defp expression(policy, :write), do: policy.with_check

  defp applies_to?(%Policy{roles: roles}, role), do: "public" in roles or role in roles

  defp unmodelled_roles(%Policy{roles: roles}, %Profile{policy_roles: policy_roles}),
    do: roles -- ["public" | policy_roles]

  ## Policies and functions

  defp policy(input, %Policy{} = parsed, profile) do
    # Realtime only reads and inserts, so UPDATE and DELETE policies never apply.
    used = parsed.cmd in (commands(:read) ++ commands(:write))

    %{
      name: parsed.name,
      command: Map.get(@commands, parsed.cmd, parsed.cmd),
      used: used,
      permissive: parsed.permissive,
      roles: parsed.roles,
      unmodelled_roles: if(used, do: unmodelled_roles(parsed, profile), else: []),
      using: expression_report(input.qual, parsed.using),
      with_check: expression_report(input.with_check, parsed.with_check)
    }
  end

  defp expression_report(nil, _parsed), do: nil
  defp expression_report(text, parsed), do: %{text: text, unsupported: unsupported(parsed)}

  # A tree without unsupported nodes is still unsupported as a policy if it isn't a boolean, see
  # `PolicyEval.PolicySet`.
  defp unsupported({ir, type}) do
    reasons =
      case IR.unsupported_reasons(ir) do
        [] when type != :bool -> [{:not_boolean, type}]
        reasons -> reasons
      end

    Enum.map(reasons, &{Reason.category({:unsupported, &1}), &1})
  end

  # The same lookup as `PolicyEval.Resolver`: one definition is inlined if it is a known one, and two
  # or more are overloads. The status names the `why` of the resolver's `{:function, name, why}`.
  defp functions(definitions, profile) do
    for {schema, name} <- profile.functions |> Enum.map(&{&1.schema, &1.name}) |> Enum.uniq() do
      matching = Enum.filter(definitions, &(&1.schema == schema and &1.name == name))

      status =
        case matching do
          [] ->
            :not_in_snapshot

          [definition] ->
            if match?({:ok, _}, Catalog.inline(definition, profile.functions)), do: :known, else: :unknown_definition

          [_ | _] ->
            :overloaded
        end

      %{name: "#{schema}.#{name}", status: status, definitions: matching}
    end
  end
end
