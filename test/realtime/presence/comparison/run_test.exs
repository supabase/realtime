defmodule Realtime.Presence.Comparison.RunTest do
  # The tracker module is named, so these tests cannot run concurrently with other users of it.
  use ExUnit.Case, async: false

  alias Realtime.Presence.Comparison
  alias Realtime.Tenants
  alias Realtime.Test.PresenceUsageTracker, as: Tracker

  setup do
    start_supervised!({Tracker, pool_size: 1})

    rollcall = :"rollcall-#{System.unique_integer([:positive])}"
    start_supervised!({Rollcall, name: rollcall})

    tenant = "tenant-#{System.unique_integer([:positive])}"

    {:ok, tenant: tenant, rollcall: rollcall, topic: Tenants.tenant_topic(tenant, "room")}
  end

  describe "run/2" do
    test "gives the outcome clean without a wait when the views are equal", ctx do
      {:ok, ref} = Tracker.track(self(), ctx.topic, "k1", %{})
      track_rollcall(ctx, ctx.topic, ref)

      sleep = fn _ms -> flunk("run/2 waited when no candidate was open") end

      assert {:ok, %{outcome: :clean, entries: 1, rungs: [], persistent: []}} = run(ctx, sleep: sleep)
    end

    test "gives the outcome transient and stops at the rung where the views agree", ctx do
      {:ok, ref} = Tracker.track(self(), ctx.topic, "k1", %{})
      :ok = Rollcall.ensure_started(ctx.rollcall, ctx.tenant)

      # Rollcall gets the ref during the second wait, so the rung at 3000 finds it.
      sleep = script([fn -> :ok end, fn -> track_rollcall(ctx, ctx.topic, ref) end])

      assert {:ok, summary} = run(ctx, sleep: sleep)

      assert summary.outcome == :transient
      assert summary.candidates == %{missing: 1, ghost: 0}

      # No row for the rung at 5000: the loop ends when no candidate is open.
      assert summary.rungs == [
               %{rung: 1_000, kind: :missing, open: 1, converged: 0, gone: 0},
               %{rung: 3_000, kind: :missing, open: 0, converged: 1, gone: 0}
             ]
    end

    test "gives the outcome persistent for a missing ref and a ghost ref that stay open", ctx do
      missing_topic = Tenants.tenant_topic(ctx.tenant, "missing")
      ghost_topic = Tenants.tenant_topic(ctx.tenant, "ghost")

      {:ok, missing_ref} = Tracker.track(self(), missing_topic, "k1", %{})
      track_rollcall(ctx, ghost_topic, "ghost-ref")

      assert {:ok, summary} = run(ctx, [])

      assert summary.outcome == :persistent

      assert Enum.sort(summary.persistent) ==
               [{ghost_topic, "ghost-ref", :ghost}, {missing_topic, missing_ref, :missing}]

      # Both candidates stay open at every rung of the ladder.
      assert summary.rungs |> Enum.map(&{&1.rung, &1.kind, &1.open}) |> Enum.sort() ==
               for(rung <- [1_000, 3_000, 5_000, 10_000, 15_000], kind <- [:ghost, :missing], do: {rung, kind, 1})
    end

    test "returns :discarded when no Rollcall tracker runs at the first read, even with no Phoenix entry", ctx do
      assert Rollcall.Tracker.whereis(ctx.rollcall, ctx.tenant) == nil

      sleep = fn _ms -> flunk("run/2 waited for a tenant with no tracker") end

      assert run(ctx, sleep: sleep) == :discarded
    end

    test "returns :discarded when the Rollcall tracker stops during the ladder", ctx do
      {:ok, _ref} = Tracker.track(self(), ctx.topic, "k1", %{})
      track_rollcall(ctx, Tenants.tenant_topic(ctx.tenant, "other"), "other-ref")

      tracker = Rollcall.Tracker.whereis(ctx.rollcall, ctx.tenant)
      assert is_pid(tracker)

      # The tracker stops during the second wait. The read at rung 3000 finds an empty view, which
      # looks like a persistent divergence.
      sleep = script([fn -> :ok end, fn -> GenServer.stop(tracker) end])

      assert run(ctx, sleep: sleep) == :discarded
    end
  end

  describe "run/2 waits and discards" do
    test "returns :discarded when the empty read of a stopped tracker closes every candidate", ctx do
      # The only candidate is a ghost. The empty read after the stop turns it into `:gone`, so the
      # loop ends with no open candidate and only the check of the tracker shows the stop.
      track_rollcall(ctx, ctx.topic, "ghost-ref")
      tracker = Rollcall.Tracker.whereis(ctx.rollcall, ctx.tenant)

      sleep = script([fn -> GenServer.stop(tracker) end])

      assert run(ctx, sleep: sleep) == :discarded
    end

    test "waits for the time that is left until the rung is due, not for the rung", ctx do
      {:ok, _ref} = Tracker.track(self(), ctx.topic, "k1", %{})
      :ok = Rollcall.ensure_started(ctx.rollcall, ctx.tenant)

      # A real wait of 60 ms, instead of the 1000 ms of the first rung, keeps the test short.
      sleep = fn ms ->
        send(self(), {:wait, ms})
        Process.sleep(60)
      end

      assert {:ok, _summary} = run(ctx, sleep: sleep)

      assert_received {:wait, first}
      assert_received {:wait, second}

      # The first wait is at most 1000 ms. At least 60 ms passed before the second wait, so the time
      # left to the rung at 3000 is at most 2940 ms. A wait for the whole rung would be 3000.
      assert first in 1..1_000
      assert second in 0..2_940
    end
  end

  defp run(ctx, opts) do
    defaults = [phoenix: Tracker, rollcall: ctx.rollcall, sleep: &no_wait/1]

    Comparison.run(ctx.tenant, Keyword.merge(defaults, opts))
  end

  defp no_wait(_ms), do: :ok

  # Returns a `:sleep` function that runs the nth action at the nth wait, and does not wait.
  # A wait after the last action does nothing.
  defp script(actions) do
    {:ok, agent} = Agent.start_link(fn -> actions end)

    fn _ms ->
      action =
        Agent.get_and_update(agent, fn
          [action | rest] -> {action, rest}
          [] -> {fn -> :ok end, []}
        end)

      action.()
    end
  end

  # The test process owns the entry. It leaves with the test.
  defp track_rollcall(ctx, topic, ref) do
    {:ok, ^ref} = Rollcall.track(ctx.rollcall, self(), ctx.tenant, topic, "k1", %{}, ref: ref)
  end
end
