defmodule Realtime.PromEx.Plugins.PolicyEval do
  @moduledoc """
  Metrics for `Realtime.Tenants.PolicyEvalShadow`'s shadow-mode comparison: policy_eval's decision
  against the real RLS check. Off by default, behind the `"policy_eval_shadow"` feature flag — expect
  these to read as zero/absent until it's enabled for a tenant.

  No `tenant` tag: shadow mode is meant to roll out to every tenant, and a per-tenant series for each
  of these would multiply the metric count by the number of active tenants. The per-tenant detail
  that matters is in the logs instead: `PolicyEvalShadowMismatch`, `PolicyEvalShadowException` and
  `PolicyEvalUnsupportedPolicies` all name the tenant in their message.

  `decisions_total` (counter): how often a decision matched, mismatched, fell back, or had no real
  answer to compare against (`outcome` and `extension` tags). The `reason` tag is the bounded category
  of a fallback (`PolicyEval.Reason.category/1`), `none` for every other outcome. The `role` tag is
  the caller's role: `anon`, `authenticated`, or one of the platform roles `service_role`,
  `postgres` and `supabase_admin` by name, `other` for any role the tenant made, `none` without a
  role (`PolicyEval.Profile.reported_role/2`). Only `anon` and `authenticated` are decided, so the
  other values only appear with `outcome="fallback", reason="role"`. `shadow_duration` (distribution): what
  deciding locally would have cost. Compare it against the existing
  `realtime_tenants_read_authorization_check`/`write_authorization_check` distributions for what the
  real check actually costs, rather than duplicating that measurement here — note those are
  millisecond-bucketed (DB round trips) while this one is microsecond-bucketed: a decision on a warm
  snapshot cache is ~11µs (policy_eval's own measured number), only reaching millisecond range on a cold
  cache, which triggers the loader's own DB round trip.
  """
  use PromEx.Plugin

  defmodule Latency.Buckets do
    @moduledoc false
    # Microseconds. 10-10_000 covers a decision on a warm cache (policy_eval's own ~11µs, plus env
    # building); 50_000-1_000_000 covers a cold cache, which falls back to the loader's full DB round
    # trip.
    use Peep.Buckets.Custom,
      buckets: [10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 50_000, 250_000, 1_000_000]
  end

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :realtime_policy_eval_shadow_metrics,
      for operation <- [:read, :write] do
        event = [:realtime, :tenants, :policy_eval, :shadow, operation]

        [
          counter(
            event ++ [:decisions, :total],
            event_name: event,
            description:
              "Count of policy_eval shadow #{operation} decisions, by outcome, extension, (for a fallback) reason " <>
                "category and the caller's role.",
            tags: [:outcome, :extension, :reason, :role]
          ),
          counter(
            event ++ [:unavailable, :total],
            event_name: event ++ [:unavailable],
            description: "Count of policy_eval shadow #{operation} checks that couldn't load a snapshot."
          ),
          counter(
            event ++ [:exceptions, :total],
            event_name: event ++ [:exception],
            description:
              "Count of policy_eval shadow #{operation} checks that raised. Should stay at zero; everything " <>
                "upstream of this is supposed to return a tagged result instead of raising.",
            tags: [:extension]
          ),
          distribution(
            event ++ [:shadow_duration],
            event_name: event ++ [:timing],
            measurement: :shadow_duration,
            unit: {:native, :microsecond},
            description:
              "Latency, in microseconds, of the whole policy_eval shadow #{operation} pipeline (cache fetch included).",
            reporter_options: [peep_bucket_calculator: Latency.Buckets]
          )
        ]
      end
      |> List.flatten()
    )
  end
end
