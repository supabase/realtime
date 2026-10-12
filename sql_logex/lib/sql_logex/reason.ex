defmodule SqlLogex.Reason do
  @moduledoc """
  A bounded category for the reason of a `{:fallback, reason}` from `SqlLogex.decide/3`, to tag
  a metric with. The reasons themselves are safe to log (see `SqlLogex.PolicySet`), but there are
  too many of them for a tag.

    * the setup: `:role`, `:table` (RLS off or forced, no grant, a role that bypasses RLS or isn't
      in the snapshot), `:policy_role`, `:select_policy` and `:no_expression`
    * the input: `:raises` (Postgres raises on it too) and `:input` (something the evaluator can't
      model for it, like non-ASCII text in a regex)
    * the policy: `:function_supabase` (`auth` and `realtime`), `:function_builtin`,
      `:function_custom`, `:operator`, `:type`, `:column`, `:setting` and `:unparsed`
    * `:exception`, and `:other` for a reason this module doesn't know
  """

  @type category ::
          :role
          | :table
          | :policy_role
          | :select_policy
          | :no_expression
          | :raises
          | :input
          | :function_supabase
          | :function_builtin
          | :function_custom
          | :operator
          | :type
          | :column
          | :setting
          | :unparsed
          | :exception
          | :other

  @input [
    :regex_non_ascii,
    :bool_in_non_ascii,
    :invalid_utf8,
    :jsonb_number_text,
    :jsonb_container_text,
    :jsonb_too_deeply_nested,
    :jsonb_number_range,
    :jsonb_number_token
  ]

  @type_atoms [:untyped_string_literal, :untyped_null, :number_literal, :textanycat_non_uuid, :array_not_constructor]

  @doc "The category of the `reason` in a `{:fallback, reason}`."
  @spec category(term()) :: category
  def category({:role, _role}), do: :role
  def category(:rls_disabled), do: :table
  def category(:rls_forced), do: :table
  def category({:role_not_in_snapshot, _role}), do: :table
  def category({:bypass_rls, _role}), do: :table
  def category({:missing_grant, _role, _grant}), do: :table
  def category(:unmodelled_policy_role), do: :policy_role
  def category(:select_policy_unsupported), do: :select_policy
  def category(:policy_without_expression), do: :no_expression
  def category({:exception, _module}), do: :exception
  def category({:unsupported, reason}), do: expression(reason)
  def category(_reason), do: :other

  # What the policy or the input made unsupported.
  defp expression({:raises, _sqlstate, _detail}), do: :raises
  defp expression(reason) when reason in @input, do: :input
  defp expression({:function, :other_schema, _why}), do: :function_custom

  defp expression({:function, name, _why}) when is_binary(name) do
    if String.starts_with?(name, ["auth.", "realtime."]), do: :function_supabase, else: :function_builtin
  end

  defp expression({:operator, _op, _left, _right}), do: :operator
  defp expression({:array_operator, _op, _quantifier}), do: :operator
  defp expression(:regex_not_literal), do: :operator
  defp expression({:cast, _from, _to}), do: :type
  defp expression({:coalesce_types, _types}), do: :type
  defp expression({:nullif, _left, _right}), do: :type
  defp expression({:array_types, _lhs, _elements}), do: :type
  defp expression({:not_boolean, _type}), do: :type
  defp expression(reason) when reason in @type_atoms, do: :type
  defp expression({:column, _name}), do: :column
  defp expression({:unbound_column, _name}), do: :column
  defp expression({:unknown_setting, _name}), do: :setting
  defp expression({:unparsed, _keyword}), do: :unparsed
  defp expression({:unknown_node, _tag}), do: :unparsed
  defp expression(_reason), do: :other
end
