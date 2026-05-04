defmodule Realtime.Telemetry.Logger do
  @moduledoc """
  We can log less frequent Telemetry events to get data into BigQuery.
  """

  require Logger
  use Realtime.Logs

  use GenServer

  @events [
    [:realtime, :connections],
    [:realtime, :rate_counter, :channel, :events],
    [:realtime, :rate_counter, :channel, :db_events],
    [:realtime, :rate_counter, :channel, :presence_events],
    [:realtime, :tenants, :migrations, :start],
    [:realtime, :tenants, :migrations, :stop],
    [:realtime, :tenants, :migrations, :exception],
    [:realtime, :tenants, :migrations, :reconcile, :stop],
    [:realtime, :tenants, :migrations, :reconcile, :exception]
  ]

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def init(handler_id: handler_id) do
    :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, [])

    {:ok, []}
  end

  @doc """
  Logs billing metrics for a tenant aggregated and emitted by a PromEx metric poller.
  """
  def handle_event(event, measurements, %{tenant: tenant}, _config) do
    meta = %{project: tenant, measurements: measurements}
    Logger.info(["Billing metrics: ", inspect(event)], meta)
    :ok
  end

  def handle_event([:realtime, :tenants, :migrations, :start], _measurements, metadata, _config) do
    Logger.info(
      "Applying migrations to #{metadata.hostname}",
      project: metadata.external_id
    )
  end

  def handle_event([:realtime, :tenants, :migrations, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info(
      "Finished applying #{metadata.migrations_executed} migrations for tenant #{metadata.external_id} in #{duration_ms}ms",
      project: metadata.external_id
    )
  end

  def handle_event([:realtime, :tenants, :migrations, :exception], _measurements, metadata, _config) do
    log_error(
      "MigrationsFailedToRun",
      metadata.reason,
      project: metadata.external_id,
      error_code: metadata.error_code
    )
  end

  def handle_event([:realtime, :tenants, :migrations, :reconcile, :stop], _measurements, metadata, _config) do
    log_warning(
      "MigrationCountMismatch",
      "Reconciling migrations_ran for tenant #{metadata.external_id} cached=#{metadata.cached_migrations_ran} database=#{metadata.database_migrations_ran}",
      project: metadata.external_id
    )
  end

  def handle_event([:realtime, :tenants, :migrations, :reconcile, :exception], _measurements, metadata, _config) do
    log_error(
      "MigrationCountMismatchReconcileFailed",
      metadata.reason,
      project: metadata.external_id
    )
  end

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
