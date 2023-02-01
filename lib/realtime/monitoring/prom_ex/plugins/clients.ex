defmodule Realtime.PromEx.Plugins.Clients do
  @moduledoc false

  use PromEx.Plugin
  require Logger
  alias Realtime.Telemetry

  @impl true
  def polling_metrics(opts) do
    poll_rate = Keyword.get(opts, :poll_rate, 5_000)

    [
      metrics(poll_rate)
    ]
  end

  defp metrics(poll_rate) do
    Polling.build(
      :realtime_tenant_events,
      poll_rate,
      {__MODULE__, :execute_tenant_metrics, []},
      [
        last_value(
          [:realtime, :connections, :connected],
          event_name: [:realtime, :connections],
          description: "The total count of connected clients for a tenant.",
          measurement: :connected,
          tags: [:tenant]
        ),
        last_value(
          [:realtime, :connections, :limit],
          event_name: [:realtime, :connections],
          description: "The total count of connected clients for a tenant.",
          measurement: :limit,
          tags: [:tenant]
        )
      ]
    )
  end

  def execute_tenant_metrics() do
    tenants = :syn.group_names(:users)

    for t <- tenants do
      count = Realtime.UsersCounter.tenant_users(Node.self(), t)
      tenant = Realtime.Api.get_tenant_by_external_id(t)

      Telemetry.execute(
        [:realtime, :connections],
        %{connected: count, limit: tenant.max_concurrent_users},
        %{tenant: t}
      )
    end
  end
end
