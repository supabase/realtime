defmodule Rollcall.Tracker.CommittedChanges do
  @moduledoc """
  The changes that the view committed, with the entries that left.

  `Rollcall.Tracker.Changes` names a leave by its id. `Rollcall.Tracker.View.write/2`
  deletes the entry of each leave and returns the entries in `leaves`, with
  their key and meta. The view no longer holds them after the write, so the
  tracker publishes from this struct.

  `joins` and `leaves` are both `Rollcall.partitioned_entry()`s.
  """

  @enforce_keys [:joins, :leaves]
  defstruct [:joins, :leaves]

  @type t :: %__MODULE__{
          joins: [Rollcall.partitioned_entry()],
          leaves: [Rollcall.partitioned_entry()]
        }

  @doc """
  Returns a map from each partition that has a join or a leave to its diff.

  A diff is `{joins, leaves}`. Each side is a list of `{ref, key, meta}`
  tuples. The order of the entries in a diff is not defined. Changes with no
  join and no leave return `%{}`, so the tracker never publishes an empty diff.
  """
  @spec partition_diffs(t()) :: %{Rollcall.partition() => Rollcall.partition_diff()}
  def partition_diffs(%__MODULE__{joins: joins, leaves: leaves}) do
    join_diff =
      Enum.reduce(joins, %{}, fn {partition, ref, key, meta}, acc ->
        diff_entry = {ref, key, meta}

        Map.update(acc, partition, {[diff_entry], []}, fn {joins, leaves} ->
          {[diff_entry | joins], leaves}
        end)
      end)

    Enum.reduce(leaves, join_diff, fn {partition, ref, key, meta}, acc ->
      diff_entry = {ref, key, meta}

      Map.update(acc, partition, {[], [diff_entry]}, fn {joins, leaves} ->
        {joins, [diff_entry | leaves]}
      end)
    end)
  end
end
