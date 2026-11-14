defmodule PolicyEval do
  @moduledoc """
  Evaluates Postgres row-level security policies in Elixir.

  The input is the expression text Postgres itself produces with `pg_get_expr`, not SQL written by
  hand. Every answer either matches what Postgres would decide or is a fallback, in which case the
  caller asks the database instead.

  This library has no runtime dependencies: plain data in, plain result out.

  What the library knows about the table it decides for, and about the platform around it, is in
  one place, the profile (`PolicyEval.Profile`). The caller builds it.

  ## Unsupported parts make a decision a fallback

  An expression the library doesn't model, or an input Postgres raises on, is `{:unsupported, _}`
  and makes the decision a fallback, even where another part of the policy set could decide it
  (`true OR <unsupported>`). See `PolicyEval.Eval` for why.

  The pipeline, each stage pure:

    1. `PolicyEval.Parser` turns the text of a policy expression into an `PolicyEval.AST`
    2. `PolicyEval.Resolver` binds it into `PolicyEval.IR`, inlining the function definitions of the
       profile that `PolicyEval.Catalog` recognises. `PolicyEval.Snapshot.new/2` does 1 and 2 once per
       policy
    3. `PolicyEval.Eval` evaluates the IR against an `PolicyEval.Env` of session settings and row,
       using the primitives in `PolicyEval.Value` and `PolicyEval.Jsonb`
    4. `PolicyEval.PolicySet` picks the policies that apply and combines them, which is `decide/3`
  """

  alias PolicyEval.PolicySet

  @doc """
  Decides whether the role in `env` may `:read` or `:write` the row in `env`.

  Returns `:allow` or `:deny`, or `{:fallback, reason}` when only the database can tell. See
  `PolicyEval.PolicySet`.
  """
  @spec decide(PolicyEval.Snapshot.t(), PolicyEval.Env.t(), :read | :write) :: PolicySet.decision()
  def decide(snapshot, env, operation), do: PolicySet.decide(snapshot, env, operation)
end
