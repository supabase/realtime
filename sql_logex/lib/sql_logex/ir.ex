defmodule SqlLogex.IR do
  @moduledoc """
  The tree `SqlLogex.Resolver` binds an `SqlLogex.AST` into, and `SqlLogex.Eval` evaluates.

  IR stands for intermediate representation, the compiler term for the form a program takes
  between parsing and running it. The AST says what the text says; the IR says what Postgres
  will do. Take the policy expression `(realtime.topic() = ('user:'::text || auth.uid()))`.
  The AST is only syntax: `=` and `||` are strings, and the functions are names.

      {:op, "=", {:func, "realtime", "topic", []},
       {:op, "||", {:cast, {:const, :string, "user:"}, "text"}, {:func, "auth", "uid", []}}}

  The IR knows the types, so `=` on two texts is `texteq` and `||` on text and uuid is
  `textanycat`. The cast of a literal is already done, and both functions are replaced by
  their bodies (here the ones of the supabase/postgres image):

      {:apply, Value, :text_eq, [
        {:apply, Value, :nullif, [{:setting, "realtime.topic"}, {:lit, {:text, ""}}]},
        {:apply, Value, :textanycat, [
          {:lit, {:text, "user:"}},
          {:apply, Value, :uuid_in, [
            {:apply, Value, :nullif, [{:setting, "request.jwt.claim.sub"}, {:lit, {:text, ""}}]}
          ]}
        ]}
      ]}

  Every operator, cast and function call is bound to the primitive in `SqlLogex.Value` or
  `SqlLogex.Jsonb` that mirrors it, and known functions such as `auth.uid()` are inlined as the
  tree of their body, the way the Postgres planner inlines SQL functions. What can't be bound
  becomes `{:unsupported, reason}` in place.

  What makes this the substitution mechanism is that only two nodes read the outside world:

    * `{:setting, name}`: `current_setting(name, true)`, looked up in `SqlLogex.Env` settings,
      which hold the exact strings Realtime passes to `set_config`
    * `{:column, name}`: a column of the row the policy is checked against, looked up in
      `SqlLogex.Env` row

  Nothing is substituted into text. Binding a JWT or a row means filling in the env, and later a
  partial evaluator can bind the settings once and leave the columns as a residual predicate.

  Two forms need a note:

    * `{:array, elements}` is an `ARRAY[...]` constructor. It evaluates to a plain list of the
      evaluated elements, and only appears as an argument of `:apply`
    * `{:lit, mode}` with `:case_sensitive` or `:case_insensitive` is the mode argument of
      `SqlLogex.Value.regex_match/3`. It is not a SQL value, just a constant handed to a primitive
  """

  @type t ::
          {:lit, SqlLogex.Value.t() | :case_sensitive | :case_insensitive}
          | {:setting, name :: String.t()}
          | {:column, name :: String.t()}
          | {:apply, module(), function :: atom(), [t]}
          | {:array, [t]}
          | {:and, [t]}
          | {:or, [t]}
          | {:not, t}
          | {:coalesce, [t]}
          | {:unsupported, reason :: term()}

  @doc """
  Whether `ir` has no `{:unsupported, _}` node anywhere in it.

  This is about the tree, not about evaluating it: a supported tree can still evaluate to
  `{:unsupported, _}`, for instance when a cast is given an input Postgres raises on. It is what
  lets a caller tell that an expression is fully modelled without needing the env, so without
  evaluating it. A node that isn't one of `t/0` is not supported.
  """
  @spec supported?(t) :: boolean()
  def supported?({:unsupported, _reason}), do: false
  def supported?({leaf, _name_or_value}) when leaf in [:lit, :setting, :column], do: true
  def supported?({:not, child}), do: supported?(child)

  def supported?({node, children}) when node in [:array, :and, :or, :coalesce] and is_list(children),
    do: Enum.all?(children, &supported?/1)

  def supported?({:apply, _module, _function, args}) when is_list(args), do: Enum.all?(args, &supported?/1)
  def supported?(_other), do: false
end
