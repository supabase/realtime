defmodule SqlLogex do
  @moduledoc """
  Evaluates Postgres row-level security policies in Elixir.

  The input is the expression text Postgres itself produces with `pg_get_expr`, not SQL written by
  hand. Every answer either matches what Postgres would decide or is a fallback, in which case the
  caller asks the database instead.

  This library has no Realtime, Ecto or Postgrex dependencies: plain data in, plain result out.

  ## Unsupported parts make a decision a fallback

  An expression the library doesn't model, or an input Postgres raises on, is `{:unsupported, _}`
  and makes the decision a fallback, even where another part of the policy set could decide it
  (`true OR <unsupported>`). See `SqlLogex.Eval` for why.

  The pipeline, each stage pure:

    1. `SqlLogex.Parser` turns the text of a policy expression into an `SqlLogex.AST`
    2. `SqlLogex.Resolver` binds it into `SqlLogex.IR`, inlining the function definitions
       `SqlLogex.Catalog` recognises. `SqlLogex.Snapshot.new/1` does 1 and 2 once per policy
    3. `SqlLogex.Eval` evaluates the IR against an `SqlLogex.Env` of session settings and row,
       using the primitives in `SqlLogex.Value` and `SqlLogex.Jsonb`
    4. `SqlLogex.PolicySet` picks the policies that apply and combines them, which is `decide/3`
  """

  alias SqlLogex.PolicySet

  @doc """
  Decides whether the role in `env` may `:read` or `:write` the row in `env`.

  Returns `:allow` or `:deny`, or `{:fallback, reason}` when only the database can tell. See
  `SqlLogex.PolicySet`.
  """
  @spec decide(SqlLogex.Snapshot.t(), SqlLogex.Env.t(), :read | :write) :: PolicySet.decision()
  def decide(snapshot, env, operation), do: PolicySet.decide(snapshot, env, operation)
end
