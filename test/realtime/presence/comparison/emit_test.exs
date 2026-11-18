defmodule Realtime.Presence.Comparison.EmitTest do
  # The handlers are global, so another test that emits the same events would reach them.
  use ExUnit.Case, async: false

  alias Realtime.Presence.Comparison

  @prefix [:realtime, :presence, :compare]
  @names [:comparison, :candidates, :rung, :persistent]

  # Three missing candidates and one ghost. Two missing candidates are persistent. The ghost and
  # the third missing candidate converged.
  @summary %{
    outcome: :persistent,
    entries: 7,
    candidates: %{missing: 3, ghost: 1},
    persistent: [{"t:a", "r1", :missing}, {"t:a", "r2", :missing}],
    rungs: [
      %{rung: 1_000, kind: :missing, open: 3, converged: 0, gone: 0},
      %{rung: 1_000, kind: :ghost, open: 1, converged: 0, gone: 0},
      %{rung: 3_000, kind: :missing, open: 2, converged: 1, gone: 0},
      %{rung: 3_000, kind: :ghost, open: 0, converged: 1, gone: 0}
    ]
  }

  setup do
    ref = :telemetry_test.attach_event_handlers(self(), Enum.map(@names, &(@prefix ++ [&1])))

    {:ok, ref: ref}
  end

  describe "emit/3" do
    test "emits one :comparison event with the entries, the duration and the outcome", ctx do
      :ok = Comparison.emit("tenant-1", {:ok, @summary}, 5_000)

      assert [{%{entries: 7, duration: 5_000}, %{tenant: "tenant-1", outcome: :persistent}}] =
               emitted(ctx.ref, :comparison)
    end

    test "emits one :candidates event for each kind, with the counts at the first read", ctx do
      :ok = Comparison.emit("tenant-1", {:ok, @summary}, 5_000)

      assert ctx.ref |> emitted(:candidates) |> by_kind() == [
               {%{count: 1}, %{tenant: "tenant-1", kind: :ghost}},
               {%{count: 3}, %{tenant: "tenant-1", kind: :missing}}
             ]
    end

    test "emits one :rung event for each row, with no tenant", ctx do
      :ok = Comparison.emit("tenant-1", {:ok, @summary}, 5_000)

      assert ctx.ref |> emitted(:rung) |> Enum.sort_by(fn {_, meta} -> {meta.rung, meta.kind} end) == [
               {%{open: 1, converged: 0, gone: 0}, %{rung: 1_000, kind: :ghost}},
               {%{open: 3, converged: 0, gone: 0}, %{rung: 1_000, kind: :missing}},
               {%{open: 0, converged: 1, gone: 0}, %{rung: 3_000, kind: :ghost}},
               {%{open: 2, converged: 1, gone: 0}, %{rung: 3_000, kind: :missing}}
             ]
    end

    test "emits a :persistent event only for a kind that has a persistent candidate", ctx do
      :ok = Comparison.emit("tenant-1", {:ok, @summary}, 5_000)

      # The summary has a ghost candidate, but no persistent ghost.
      assert emitted(ctx.ref, :persistent) == [{%{count: 2}, %{tenant: "tenant-1", kind: :missing}}]
    end

    test "emits a count of 0 for each kind, and no :rung or :persistent event, for equal views", ctx do
      clean = %{outcome: :clean, entries: 4, candidates: %{missing: 0, ghost: 0}, persistent: [], rungs: []}

      :ok = Comparison.emit("tenant-1", {:ok, clean}, 5_000)

      assert ctx.ref |> emitted(:candidates) |> by_kind() == [
               {%{count: 0}, %{tenant: "tenant-1", kind: :ghost}},
               {%{count: 0}, %{tenant: "tenant-1", kind: :missing}}
             ]

      assert emitted(ctx.ref, :rung) == []
      assert emitted(ctx.ref, :persistent) == []
    end

    test "emits only :comparison, with no entries, for a discarded comparison", ctx do
      :ok = Comparison.emit("tenant-1", :discarded, 5_000)

      assert emitted(ctx.ref, :comparison) == [{%{duration: 5_000}, %{tenant: "tenant-1", outcome: :discarded}}]

      for name <- [:candidates, :rung, :persistent], do: assert(emitted(ctx.ref, name) == [])
    end
  end

  # The order of the events is not defined. A sort of the tuples would sort by the measurements.
  defp by_kind(events), do: Enum.sort_by(events, fn {_measurements, meta} -> meta.kind end)

  # The events arrive before emit/3 returns, because telemetry calls the handler in the caller.
  defp emitted(ref, name) do
    event = @prefix ++ [name]

    Stream.repeatedly(fn ->
      receive do
        {^event, ^ref, measurements, metadata} -> {measurements, metadata}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end
end
