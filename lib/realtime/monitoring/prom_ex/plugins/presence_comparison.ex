defmodule Realtime.PromEx.Plugins.PresenceComparison do
  @moduledoc """
  A PromEx plugin that turns the telemetry events of `Realtime.Presence.Comparison` into metrics.

  The comparison checks the presence views of Phoenix and Rollcall in shadow mode. The event names
  come from `Realtime.Presence.Comparison.event/1`. The events carry the tenant, which is for logs.
  No metric has a tenant tag, so the cardinality stays low and the metrics belong in the global
  `Realtime.PromEx` registry.

  ## Metrics

    * `realtime_presence_compare_comparisons` - comparisons, by `outcome`: `clean`, `transient`,
      `persistent` or `discarded`.
    * `realtime_presence_compare_entries` - the refs in the union of the two views at the first read.
      A discarded comparison adds nothing.
    * `realtime_presence_compare_candidates` - the refs that one view holds and the other view does
      not, at the first read, by `kind`: `missing` (Phoenix only) or `ghost` (Rollcall only).
    * `realtime_presence_compare_persistent_candidates` - the candidates that were open at the
      persistent rung, by `kind`.
    * `realtime_presence_compare_candidate_rungs_open`, `_converged` and `_gone` - the candidates
      that were open, converged or gone at a check, by `rung` in milliseconds and `kind`. The share
      of the open candidates at a rung is `open / (open + converged)`.
    * `realtime_presence_compare_duration` - a distribution, in milliseconds, of the time of one
      comparison.
    * `realtime_presence_compare_sweeps` - sweeps that ended.
    * `realtime_presence_compare_sweep_tenants_listed` and `_compared` - the scopes that a sweep
      listed, and the tenants that it compared.
    * `realtime_presence_compare_sweep_duration` - a distribution, in milliseconds, of the time of
      one sweep.

  The events carry each `duration` in native time units, and the plugin converts it to milliseconds.
  """
  use PromEx.Plugin

  alias Realtime.Presence.Comparison

  defmodule Duration.Buckets do
    @moduledoc false
    # Milliseconds. A comparison with no candidate takes a few milliseconds. A comparison with a
    # candidate ends at a rung of 1, 3, 5, 10 or 15 seconds, so each bound is half a second above a
    # rung.
    use Peep.Buckets.Custom, buckets: [10, 100, 500, 1_500, 3_500, 5_500, 10_500, 15_500, 30_000]
  end

  defmodule SweepDuration.Buckets do
    @moduledoc false
    # Milliseconds. A sweep of tenants with no candidate takes milliseconds. A sweep is long when the
    # tenant tasks wait for a place, so the bounds reach the period of the scheduler.
    use Peep.Buckets.Custom, buckets: [10, 100, 1_000, 5_000, 15_000, 30_000, 60_000, 120_000, 300_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime_presence_compare_event_metrics, [
      counter(
        [:realtime, :presence, :compare, :comparisons],
        event_name: Comparison.event(:comparison),
        description:
          "Comparisons of the presence views of Phoenix and Rollcall, tagged by outcome: clean, transient, persistent or discarded.",
        tags: [:outcome]
      ),
      sum(
        [:realtime, :presence, :compare, :entries],
        event_name: Comparison.event(:comparison),
        measurement: :entries,
        # A discarded comparison has no entries. A sum counts a missing measurement as 1.
        keep: &(&1.outcome != :discarded),
        description:
          "The refs in the union of the two views at the first read of a comparison. A discarded comparison adds nothing."
      ),
      distribution(
        [:realtime, :presence, :compare, :duration],
        event_name: Comparison.event(:comparison),
        measurement: :duration,
        unit: {:native, :millisecond},
        description:
          "Time of one comparison, in milliseconds. A comparison with a candidate lasts until its last rung.",
        reporter_options: [peep_bucket_calculator: Duration.Buckets]
      ),
      sum(
        [:realtime, :presence, :compare, :candidates],
        event_name: Comparison.event(:candidates),
        measurement: :count,
        description:
          "The refs that one view holds and the other view does not, at the first read of a comparison, tagged by kind: missing (Phoenix only) or ghost (Rollcall only).",
        tags: [:kind]
      ),
      sum(
        [:realtime, :presence, :compare, :persistent, :candidates],
        event_name: Comparison.event(:persistent),
        measurement: :count,
        description: "The candidates that were still open at the persistent rung, tagged by kind.",
        tags: [:kind]
      ),
      sum(
        [:realtime, :presence, :compare, :candidate, :rungs, :open],
        event_name: Comparison.event(:rung),
        measurement: :open,
        description:
          "The candidates that were still open at a check, tagged by rung in milliseconds and by kind. The share of the open candidates at a rung is open divided by open plus converged.",
        tags: [:rung, :kind]
      ),
      sum(
        [:realtime, :presence, :compare, :candidate, :rungs, :converged],
        event_name: Comparison.event(:rung),
        measurement: :converged,
        description:
          "The candidates that converged at a check, tagged by rung in milliseconds and by kind. The ref is in both views, or only in the other view.",
        tags: [:rung, :kind]
      ),
      sum(
        [:realtime, :presence, :compare, :candidate, :rungs, :gone],
        event_name: Comparison.event(:rung),
        measurement: :gone,
        description: "The candidates that were in neither view at a check, tagged by rung in milliseconds and by kind.",
        tags: [:rung, :kind]
      ),
      counter(
        [:realtime, :presence, :compare, :sweeps],
        event_name: Comparison.event(:sweep),
        description: "Sweeps of the comparison that ended on this node."
      ),
      sum(
        [:realtime, :presence, :compare, :sweep, :tenants, :listed],
        event_name: Comparison.event(:sweep),
        measurement: :tenants_listed,
        description: "The scopes that the sweeps of the comparison listed, in all the modes."
      ),
      sum(
        [:realtime, :presence, :compare, :sweep, :tenants, :compared],
        event_name: Comparison.event(:sweep),
        measurement: :tenants_compared,
        description:
          "The tenants that the sweeps compared. A tenant task that crashed or ran past the timeout is not in this count."
      ),
      distribution(
        [:realtime, :presence, :compare, :sweep, :duration],
        event_name: Comparison.event(:sweep),
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Time of one sweep of the comparison, in milliseconds.",
        reporter_options: [peep_bucket_calculator: SweepDuration.Buckets]
      )
    ])
  end
end
