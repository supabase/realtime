defmodule PreparedStatementAssertions do
  @moduledoc false
  import ExUnit.Assertions

  # A transaction pins the backend through a pooler. Match SQL rather than
  # client statement names, and compare deltas because pooled sessions persist.
  def assert_reused(conn, pattern, operation) do
    assert {:ok, :verified} =
             Postgrex.transaction(conn, fn tx ->
               before = snapshot(tx, pattern)
               operation.(tx, 1)
               first = snapshot(tx, pattern)
               changed = Enum.reject(first, fn {key, count} -> Map.get(before, key, 0) == count end)
               assert [{key, count}] = changed
               assert count == Map.get(before, key, 0) + 1

               operation.(tx, 2)
               assert snapshot(tx, pattern) == Map.update!(first, key, &(&1 + 1))
               :verified
             end)
  end

  defp snapshot(conn, pattern) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        """
        SELECT name, prepare_time, generic_plans + custom_plans
        FROM pg_prepared_statements WHERE statement ILIKE $1
        """,
        [pattern]
      )

    Map.new(rows, fn [name, prepared_at, count] -> {{name, prepared_at}, count} end)
  end
end
