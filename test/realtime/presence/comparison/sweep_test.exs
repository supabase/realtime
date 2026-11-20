defmodule Realtime.Presence.Comparison.SweepTest do
  # The mode comes from the feature flags, and the tenant tasks run in other processes. The stubs
  # are global, so these tests cannot run at the same time as other tests.
  use ExUnit.Case, async: false
  use Mimic

  setup :set_mimic_global

  alias Realtime.Presence.Comparison
  alias Realtime.Presence.Comparison.Sweep
  alias Realtime.Test.PresenceUsageTracker, as: Tracker

  @event [:realtime, :presence, :compare]

  setup do
    start_supervised!({Tracker, pool_size: 1})

    rollcall = :"rollcall-#{System.unique_integer([:positive])}"
    start_supervised!({Rollcall, name: rollcall})

    ref = :telemetry_test.attach_event_handlers(self(), [@event ++ [:comparison], @event ++ [:sweep]])

    stub(Realtime.FeatureFlags, :enabled?, fn "presence_comparison" -> true end)

    {:ok, rollcall: rollcall, ref: ref}
  end

  describe "run/2" do
    test "compares nothing and emits no event when the presence_comparison flag is off", ctx do
      start_tenants(ctx, %{"shadow-tenant" => :shadow})
      stub(Realtime.FeatureFlags, :enabled?, fn "presence_comparison" -> false end)

      assert :ok = sweep(ctx, 0)

      assert compared(ctx.ref) == []
      assert sweep_events(ctx.ref) == []
    end

    test "compares only the tenants in the shadow mode, and counts every scope as listed", ctx do
      modes = %{"shadow-tenant" => :shadow, "phoenix-tenant" => :phoenix, "rollcall-tenant" => :rollcall}
      start_tenants(ctx, modes)

      assert :ok = sweep(ctx, 0)

      assert compared(ctx.ref) == ["shadow-tenant"]

      assert [{%{tenants_listed: 3, tenants_compared: 1, duration: duration}, metadata}] = sweep_events(ctx.ref)
      assert is_integer(duration)
      assert metadata == %{}
    end

    test "covers every tenant once in as many sweeps as there are groups", ctx do
      tenants = for n <- 1..12, do: "sampled-#{n}"
      start_tenants(ctx, Map.new(tenants, &{&1, :shadow}))

      for n <- 0..2, do: :ok = sweep(ctx, n, groups: 3)

      assert Enum.sort(compared(ctx.ref)) == Enum.sort(tenants)

      # One sweep that compared every tenant would also cover each tenant once.
      assert Enum.all?(sweep_events(ctx.ref), fn {measurements, _} -> measurements.tenants_compared < 12 end)
    end

    test "uses 8 sampling groups by default", ctx do
      tenants = for n <- 1..40, do: "default-#{n}"
      start_tenants(ctx, Map.new(tenants, &{&1, :shadow}))

      for n <- 0..7 do
        :ok = Sweep.run(n, rollcall: ctx.rollcall, phoenix: Tracker, sleep: fn _ms -> :ok end)
      end

      # With fewer groups, a tenant has two turns in 8 sweeps. With more groups, some have none.
      assert Enum.sort(compared(ctx.ref)) == Enum.sort(tenants)
    end

    test "ends the sweep for the other tenants when a tenant task crashes or exceeds the timeout", ctx do
      tenants = ["ok-1", "ok-2", "crash", "hang"]
      start_tenants(ctx, Map.new(tenants, &{&1, :shadow}))

      stub(Comparison, :run, fn
        "crash", _opts -> raise "boom"
        "hang", _opts -> Process.sleep(:infinity)
        tenant, opts -> call_original(Comparison, :run, [tenant, opts])
      end)

      assert :ok = sweep(ctx, 0, timeout: 200)

      assert Enum.sort(compared(ctx.ref)) == ["ok-1", "ok-2"]
      assert [{%{tenants_listed: 4, tenants_compared: 2}, _}] = sweep_events(ctx.ref)
    end

    test "runs no more tenant tasks at the same time than the concurrency", ctx do
      start_tenants(ctx, Map.new(1..6, &{"busy-#{&1}", :shadow}))

      # Index 0 counts the tasks that run now. Index 1 holds the most that ran at the same time.
      counters = :counters.new(2, [:atomics])

      stub(Comparison, :run, fn tenant, opts ->
        :counters.add(counters, 1, 1)
        :counters.put(counters, 2, max(:counters.get(counters, 2), :counters.get(counters, 1)))
        Process.sleep(30)
        :counters.sub(counters, 1, 1)
        call_original(Comparison, :run, [tenant, opts])
      end)

      assert :ok = sweep(ctx, 0, concurrency: 2)

      assert :counters.get(counters, 2) <= 2
      assert length(compared(ctx.ref)) == 6
    end
  end

  # Starts a Rollcall tracker for each tenant, and sets the mode of the tenant with the flags.
  defp start_tenants(ctx, modes) do
    for {tenant, _mode} <- modes, do: :ok = Rollcall.ensure_started(ctx.rollcall, tenant)

    stub(Realtime.FeatureFlags, :enabled?, fn flag, tenant ->
      case {flag, Map.get(modes, tenant)} do
        {"presence_rollcall_primary", mode} -> mode == :rollcall
        {"presence_rollcall_shadow", mode} -> mode == :shadow
        _ -> false
      end
    end)
  end

  defp sweep(ctx, number, opts \\ []) do
    # One group, so that a sweep compares every tenant. The default is more than one group.
    defaults = [rollcall: ctx.rollcall, phoenix: Tracker, sleep: fn _ms -> :ok end, groups: 1]

    Sweep.run(number, Keyword.merge(defaults, opts))
  end

  # The tenants of the :comparison events, one entry for each event. The events arrive before
  # sweep/3 returns, because the sweep waits for its tenant tasks.
  defp compared(ref), do: ref |> events(:comparison) |> Enum.map(fn {_, metadata} -> metadata.tenant end)

  defp sweep_events(ref), do: events(ref, :sweep)

  defp events(ref, name), do: TelemetryHelper.drain(ref, @event ++ [name])
end
