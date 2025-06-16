defmodule Realtime.Telemetry.Logger do
  @moduledoc """
  We can log less frequent Telemetry events to get data into BigQuery.
  """

  require Logger

  use GenServer

  @events [
    [:realtime, :connections],
    [:realtime, :rate_counter, :channel, :events],
    [:realtime, :rate_counter, :channel, :joins],
    [:realtime, :rate_counter, :channel, :db_events],
    [:realtime, :rate_counter, :channel, :presence_events]
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

  def handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
