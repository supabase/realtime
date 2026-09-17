defmodule TestHelpers do
  @moduledoc """
  Generic helpers for tests.
  """

  @doc """
  Creates a logical replication slot.

  Temporary by default, because that is the only kind Multigres accepts without
  registering the slot for failover. Pass `temporary: false` for a slot that
  outlives the session that made it: a handful of tests need one nobody is
  consuming, or one dropped through another connection.

  `:plugin` (required) - which plugin a slot decodes with
  """
  @spec create_replication_slot(pid(), String.t(), keyword()) :: Postgrex.Result.t()
  def create_replication_slot(conn, slot_name, opts) do
    opts = Keyword.validate!(opts, [:plugin, temporary: true])
    plugin = Keyword.fetch!(opts, :plugin)

    if opts[:temporary] do
      Postgrex.query!(
        conn,
        "SELECT pg_create_logical_replication_slot(slot_name => $1::name, plugin => $2::name, temporary => true)",
        [slot_name, plugin]
      )
    else
      create_persistent_slot(conn, slot_name, plugin)
    end
  end

  # Multigres only admits a non-temporary slot when it is registered for failover, and
  # `failover` is a PostgreSQL 17 parameter, so it is passed only where the server has it.
  # Either way the slot ends up in the same state - persistent and inactive.
  defp create_persistent_slot(conn, slot_name, plugin) do
    %{rows: [[failover_supported?]]} =
      Postgrex.query!(
        conn,
        """
        SELECT EXISTS (
          SELECT 1 FROM pg_proc p, unnest(p.proargnames) n
          WHERE p.proname = 'pg_create_logical_replication_slot' AND n = 'failover'
        )
        """,
        []
      )

    if failover_supported? do
      Postgrex.query!(
        conn,
        "SELECT pg_create_logical_replication_slot(slot_name => $1::name, plugin => $2::name, failover => true)",
        [slot_name, plugin]
      )
    else
      Postgrex.query!(
        conn,
        "SELECT pg_create_logical_replication_slot(slot_name => $1::name, plugin => $2::name)",
        [slot_name, plugin]
      )
    end
  end

  @doc """
  Drops a replication slot, tolerating its absence. For cleanup, not assertions.
  """
  @spec drop_replication_slot(pid(), String.t()) :: :ok
  def drop_replication_slot(conn, slot_name) do
    Postgrex.query(conn, "SELECT pg_drop_replication_slot($1)", [slot_name])
    :ok
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

  @doc """
  The `cache_statement` names Postgrex is holding for `conn`.

  Reads Postgrex's own cache rather than `pg_prepared_statements`, because a connection pooler
  prepares every statement it forwards, keyed by the SQL text: there a query the client did not
  cache is indistinguishable from one it did, and an assertion on the catalog would still pass
  with the caching removed. What the client asked for is only visible on the client.

  This reaches into DBConnection and Postgrex internals, so it raises when it cannot find them.
  A dependency bump then fails loudly instead of silently reporting "nothing cached", which would
  turn every caller into a tautology.
  """
  @spec cached_statement_names(pid()) :: [String.t()]
  def cached_statement_names(conn) do
    owners = [conn | elem(Process.info(conn, :links), 1)]

    holder =
      Enum.find(:ets.all(), fn tab ->
        ets_info(tab, :name) == DBConnection.Holder and ets_info(tab, :owner) in owners
      end)

    if !holder, do: raise("no DBConnection.Holder table owned by #{inspect(conn)} or its links")

    protocol =
      case :ets.lookup(holder, :conn) do
        [row] -> row |> Tuple.to_list() |> Enum.find(&match?(%Postgrex.Protocol{}, &1))
        _ -> nil
      end

    if !protocol, do: raise("no %Postgrex.Protocol{} in the holder row for #{inspect(conn)}")

    case protocol.queries do
      nil -> []
      table -> table |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end

  defp ets_info(table, key) do
    :ets.info(table, key)
  rescue
    ArgumentError -> nil
  end
end
