defmodule SqlLogex.AST do
  @moduledoc """
  The tree `SqlLogex.Parser` builds from `pg_get_expr` output.

  It is syntax only: nothing is typed or bound yet, so `=` is just the string `"="` and
  `auth.uid()` is just a call by name. `SqlLogex.Resolver` decides what each node means.

  Postgres prints these expressions in a canonical form (non-pretty `ruleutils.c`), and the tree
  mirrors it closely enough that `SqlLogex.Deparse` prints the exact same text back:

    * operators, `AND`/`OR`, `NOT`, null tests and `ANY`/`ALL` always come in parentheses
    * `IN (a, b)` comes as `= ANY (ARRAY[a, b])`, and `NOT IN (a, b)` as `<> ALL (ARRAY[a, b])`
    * literals carry an explicit cast unless their type is boolean or a plain integer: `'x'::text`
    * a scalar subselect without `FROM` comes as `( SELECT auth.uid() AS uid)`

  Anything the parser doesn't recognise becomes `{:unsupported, raw}` holding the exact source
  text, so the rest of the expression can still be decided.
  """

  @type t ::
          {:bool_expr, :and | :or, [t]}
          | {:not, t}
          | {:op, operator :: String.t(), t, t}
          | {:scalar_array_op, operator :: String.t(), :any | :all, t, t}
          | {:array, [t]}
          | {:null_test, :is_null | :is_not_null, t}
          | {:cast, t, type :: String.t()}
          | {:const, :string, String.t()}
          | {:const, :number, raw :: String.t()}
          | {:const, :bool, boolean()}
          | {:const, :null}
          | {:func, schema :: String.t() | nil, name :: String.t(), [t]}
          | {:coalesce, [t]}
          | {:nullif, t, t}
          | {:column, name :: String.t()}
          | {:sublink, t, alias :: String.t() | nil}
          | {:unsupported, raw :: String.t()}
end
