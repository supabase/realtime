defmodule Realtime.PromEx.Plugins.SqlLogex do
  @moduledoc """
  Metrics for `Realtime.Tenants.SqlLogexShadow`'s shadow-mode comparison: sql_logex's decision
  against the real RLS check, per tenant. Off by default, behind the `"sql_logex_shadow"` feature
  flag — expect these to read as zero/absent until it's enabled for a tenant.

  `decisions_total` (counter): how often a decision matched, mismatched, fell back, or had no real
  answer to compare against (`outcome` and `extension` tags). The `reason` tag is the bounded category
  of a fallback (`SqlLogex.Reason.category/1`), `none` for every other outcome. `shadow_duration` (distribution): what
  deciding locally would have cost. Compare it against the existing
  `realtime_tenants_read_authorization_check`/`write_authorization_check` distributions for what the
  real check actually costs, rather than duplicating that measurement here — note those are
  millisecond-bucketed (DB round trips) while this one is microsecond-bucketed: a decision on a warm
  snapshot cache is ~11µs (sql_logex's own measured number), only reaching millisecond range on a cold
  cache, which triggers the loader's own DB round trip.
  """
  use PromEx.Plugin

  defmodule Latency.Buckets do
    @moduledoc false
    # Microseconds. 10-10_000 covers a decision on a warm cache (sql_logex's own ~11µs, plus env
    # building); 50_000-1_000_000 covers a cold cache, which falls back to the loader's full DB round
    # trip.
    use Peep.Buckets.Custom,
      buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 50_000, 250_000, 1_000_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :realtime_sql_logex_shadow_metrics,
      for operation <- [:read, :write] do
        event = [:realtime, :tenants, :sql_logex, :shadow, operation]

        [
          counter(
            event ++ [:decisions, :total],
            event_name: event,
            description:
              "Count of sql_logex shadow #{operation} decisions, by outcome, extension and (for a fallback) reason category.",
            tags: [:tenant, :outcome, :extension, :reason]
          ),
          counter(
            event ++ [:unavailable, :total],
            event_name: event ++ [:unavailable],
            description: "Count of sql_logex shadow #{operation} checks that couldn't load a snapshot.",
            tags: [:tenant]
          ),
          counter(
            event ++ [:exceptions, :total],
            event_name: event ++ [:exception],
            description:
              "Count of sql_logex shadow #{operation} checks that raised. Should stay at zero; everything " <>
                "upstream of this is supposed to return a tagged result instead of raising.",
            tags: [:tenant, :extension]
          ),
          distribution(
            event ++ [:shadow_duration],
            event_name: event ++ [:timing],
            measurement: :shadow_duration,
            unit: {:native, :microsecond},
            description:
              "Latency, in microseconds, of the whole sql_logex shadow #{operation} pipeline (cache fetch included).",
            tags: [:tenant],
            reporter_options: [peep_bucket_calculator: Latency.Buckets]
          )
        ]
      end
      |> List.flatten()
    )
  end
end
