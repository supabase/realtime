defmodule Realtime.PromEx.Plugins.ClientRequests do
  @moduledoc """
  A PromEx plugin that exposes the client request counter behind the Broadcast SLO.

  It turns the `RealtimeWeb.RequestMetrics.event/0` telemetry event into one global counter,
  `realtime_client_requests_total`. Each request increments it once, so the counter is the
  denominator of the error rate and the outcomes split it into good and bad events.

  ## Labels

    * `request` - what the client asked for, such as `broadcast`
    * `transport` - `ws` or `http`
    * `outcome` - `success`, `rejected`, `internal_failure` or `upstream_failure`
    * `reason` - why the request ended that way, such as `unauthorized`. It is `none` only when
      the outcome is `success`.

  The counter has no tenant label, so cardinality stays low and it belongs in the global
  `Realtime.PromEx` registry rather than the per-tenant one.

  ## SLI

  `success` and `rejected` are good events, because a rejection is the system working as
  intended. `internal_failure` and `upstream_failure` are bad. The error rate is
  `1 - (success + rejected) / total`. The SLO definition in `k8s-observability` selects on
  these exact names and labels, so renaming any of them needs a matching change there.

  See `RealtimeWeb.RequestMetrics` for how outcomes are recorded.
  """
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    Event.build(:realtime_client_requests_metrics, [
      counter(
        [:realtime, :client_requests, :total],
        event_name: RealtimeWeb.RequestMetrics.event(),
        description: "The total number of client requests received by the Realtime server.",
        tags: [:request, :transport, :outcome, :reason]
      )
    ])
  end
end
