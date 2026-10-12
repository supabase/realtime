defmodule SqlLogex.Reason do
  @moduledoc """
  Maps the reason of a `{:fallback, reason}` from `SqlLogex.decide/3` to one of a fixed set of
  categories, for the `reason` tag of a metric. The reasons themselves are detailed terms, like
  `{:function, "auth.role", :unknown_definition}` or `{:missing_grant, "anon", :insert}`: safe to
  log (see `SqlLogex.PolicySet`), but far too many distinct values for a tag.

  The categories, grouped by what made the evaluator fall back:

    * the role, and the table with its policies as a whole (see `SqlLogex.PolicySet`)
      * `:role`: the role isn't `anon` or `authenticated`
      * `:setup`: RLS is off or forced; the role bypasses RLS, lacks a grant or isn't in the
        snapshot; or a policy names a role other than `public`, `anon`, `authenticated` or
        `service_role`, or lacks the expression to evaluate
      * `:select_policy`: a write, where a `SELECT` or `ALL` policy that might apply to the role
        has no `USING` or something in it the evaluator can't model. `realtime.authorize` plans
        its read for a write too, so that policy might make the write fail. It doesn't say what
        the construct is: a write blocked by a subquery in a `SELECT` policy lands here, not in
        `:subquery`
    * the input of the join
      * `:raises`: Postgres raises on it too, like a sub that isn't a uuid
      * `:input`: something about it the evaluator can't model, like non-ASCII text in a regex
    * a construct in a policy that the evaluator doesn't model (see `SqlLogex.Resolver`)
      * `:function`: a function in `auth` or `realtime` the evaluator doesn't know or whose
        definition isn't a known one, a Postgres built-in, or one of the tenant's own
      * `:operator`: an operator for these types, `ANY`/`ALL`, or a regex that isn't a literal
      * `:type`: a cast or a combination of types
      * `:column`: a column other than `topic` and `extension`
      * `:setting`: a setting Realtime doesn't set
      * `:subquery`: `EXISTS`, `IN (SELECT ...)` or `(SELECT ... FROM ...)`. It reads another
        table, which only the database can do, so its share of fallbacks is what no addition here
        can win back. For writes, some of that share is in `:select_policy`
      * `:unparsed`: anything else the parser can't read
    * neither
      * `:exception`: deciding raised
      * `:other`: a reason this module doesn't map yet
  """

  @type category ::
          :role
          | :setup
          | :select_policy
          | :raises
          | :input
          | :function
          | :operator
          | :type
          | :column
          | :setting
          | :subquery
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
  def category(:rls_disabled), do: :setup
  def category(:rls_forced), do: :setup
  def category({:role_not_in_snapshot, _role}), do: :setup
  def category({:bypass_rls, _role}), do: :setup
  def category({:missing_grant, _role, _grant}), do: :setup
  def category(:unmodelled_policy_role), do: :setup
  def category(:policy_without_expression), do: :setup
  def category(:select_policy_unsupported), do: :select_policy
  def category({:exception, _module}), do: :exception
  def category({:unsupported, reason}), do: expression(reason)
  def category(_reason), do: :other

  # What the policy or the input made unsupported.
  defp expression({:raises, _sqlstate, _detail}), do: :raises
  defp expression(reason) when reason in @input, do: :input
  defp expression({:function, _name, _why}), do: :function
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
  defp expression({:unparsed, keyword}) when keyword in [:exists, :select, :subquery], do: :subquery
  defp expression({:unparsed, _keyword}), do: :unparsed
  defp expression({:unknown_node, _tag}), do: :unparsed
  defp expression(_reason), do: :other
end
