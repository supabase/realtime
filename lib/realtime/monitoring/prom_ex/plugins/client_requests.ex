defmodule Realtime.PromEx.Plugins.ClientRequests do
  @moduledoc """
  A PromEx plugin that exposes the client request counter.

  It turns the `RealtimeWeb.RequestMetrics.event/0` telemetry event into one global counter,
  `realtime_client_requests_total`. Each request increments it once, and the `outcome` label says
  how the request ended.

  ## Labels

    * `request` - what the client asked for, such as `broadcast`
    * `transport` - `ws` or `http`
    * `outcome` - `success`, `rejected`, `internal_failure` or `upstream_failure`
    * `reason` - why the request ended that way, such as `unauthorized`. It is `none` only when
      the outcome is `success`.

  The counter has no tenant label, so cardinality stays low and it belongs in the global
  `Realtime.PromEx` registry rather than the per-tenant one.

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
        # The event also carries :tenant. Keep it out of the tags, or this global counter gets a series per tenant.
        tags: [:request, :transport, :outcome, :reason]
      )
    ])
  end
end
