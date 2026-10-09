defmodule SqlLogex.Eval do
  @moduledoc """
  Evaluates `SqlLogex.IR` against an `SqlLogex.Env`.

  The result is `true`, `false`, `nil` (SQL NULL) or a value for a non-boolean expression, or
  `{:unsupported, reason}` when something couldn't be decided. Each primitive propagates
  `{:unsupported, _}` from its arguments, and `AND`, `OR` and `NOT` follow three-valued logic with
  unsupported as a fourth value.

  ## AND and OR with unsupported children

  An unsupported child makes an `AND` or `OR` unsupported, whatever its siblings are, even
  `false AND <unsupported>` or `true OR <unsupported>`:

    * `AND` is unsupported if any child is; otherwise `false` if any child is `false`; otherwise
      `nil` if any child is `nil`; otherwise `true`
    * `OR` is the mirror image: unsupported if any child is, then `true` if any child is `true`,
      then `nil`, then `false`

  Postgres short-circuits deterministically, but on the planned expression, not on the text we
  parse. Permissive policies are OR'd in reverse name order, the conjuncts of a policy's top-level
  `AND` are re-sorted by estimated cost, and planning evaluates parts before execution starts:
  constants are folded, and on the read path selectivity estimation calls stable functions such as
  `auth.uid()` in every `OR` branch. So whether an unsupported part raises can't be told from the
  text, and this library deliberately does not model the planner. The same goes for `COALESCE`,
  see `SqlLogex.Value.coalesce/1`.

  A primitive that raises (anything outside what the primitives return) raises out of `eval/2`.
  `SqlLogex.PolicySet.decide/3` turns that into a fallback.
  """

  alias SqlLogex.Env
  alias SqlLogex.IR
  alias SqlLogex.Value

  @doc "Evaluates `ir`."
  @spec eval(IR.t(), Env.t()) :: Value.result() | [Value.result()]
  def eval(ir, %Env{} = env), do: ev(ir, env)

  defp ev({:lit, value}, _env), do: value
  defp ev({:unsupported, _} = unsupported, _env), do: unsupported
  defp ev({:setting, name}, env), do: Value.current_setting(env.settings, name)

  defp ev({:column, name}, env) do
    case Map.fetch(env.row, name) do
      {:ok, value} -> value
      :error -> {:unsupported, {:unbound_column, name}}
    end
  end

  defp ev({:array, elements}, env), do: each(elements, env)

  defp ev({:apply, module, function, args}, env), do: apply(module, function, each(args, env))

  # Every argument is evaluated, an unsupported one makes the result unsupported.
  defp ev({:coalesce, args}, env), do: Value.coalesce(each(args, env))

  defp ev({:not, child}, env), do: Value.bool_not(ev(child, env))

  # AND is decided by a false child, OR by a true one.
  defp ev({:and, children}, env), do: bool_node(children, env, false)
  defp ev({:or, children}, env), do: bool_node(children, env, true)

  # `decisive` is the value that decides the node: false for AND, true for OR. An unsupported child
  # makes it unsupported. Otherwise a decisive child decides it, then a NULL child makes it NULL,
  # and otherwise it is the opposite of `decisive`.
  defp bool_node(children, env, decisive) do
    classes = children |> each(env) |> Enum.map(&classify/1)

    cond do
      unsupported = Enum.find(classes, &match?({:unsupported, _}, &1)) -> unsupported
      decisive in classes -> decisive
      nil in classes -> nil
      true -> not decisive
    end
  end

  defp each(irs, env), do: Enum.map(irs, &ev(&1, env))

  # Anything but a boolean, NULL or unsupported can't be a child of AND or OR.
  defp classify(value) when is_boolean(value) or is_nil(value), do: value
  defp classify({:unsupported, _} = unsupported), do: unsupported
  defp classify(other), do: {:unsupported, {:not_boolean, other}}
end
