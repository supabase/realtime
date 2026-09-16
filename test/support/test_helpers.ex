defmodule TestHelpers do
  @moduledoc """
  Generic helpers for tests.
  """

  @failover_supported_query """
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p, unnest(p.proargnames) n
    WHERE p.proname = 'pg_create_logical_replication_slot' AND n = 'failover'
  )
  """

  @doc """
  Creates a logical replication slot that outlives the session that made it.

  A handful of tests need exactly that: a slot nobody is consuming, or one
  dropped through another connection. Multigres only admits a non-temporary
  slot when it is registered for failover, and `failover` is a PostgreSQL 17
  parameter, so it is passed only where the server has it. Either way the slot
  ends up in the same state - persistent and inactive.
  """
  @spec create_persistent_replication_slot(pid(), String.t(), String.t()) :: Postgrex.Result.t()
  def create_persistent_replication_slot(conn, slot_name, plugin) do
    %{rows: [[failover_supported?]]} = Postgrex.query!(conn, @failover_supported_query, [])

    if failover_supported? do
      Postgrex.query!(
        conn,
        "SELECT pg_create_logical_replication_slot($1::name, $2::name, false, false, true)",
        [slot_name, plugin]
      )
    else
      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1::name, $2::name)", [slot_name, plugin])
    end
  end

  @doc """
  Runs `fun` until it returns a truthy value, retrying until it runs out of retries.
  Returns `true` if `fun` succeeded within the retries, `false` otherwise.

  ## Options

    * `:retries` - how many times to retry before giving up (default: `50`)
    * `:sleep` - how long to wait between retries, in milliseconds (default: `100`)
  """
  @spec eventually((-> as_boolean(term())), keyword()) :: boolean()
  def eventually(fun, opts \\ []) do
    retries = Keyword.get(opts, :retries, 50)
    sleep = Keyword.get(opts, :sleep, 100)

    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        opts = Keyword.put(opts, :retries, retries - 1)
        Process.sleep(sleep)
        eventually(fun, opts)
    end
  end
end
