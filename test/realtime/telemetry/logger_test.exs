defmodule Realtime.Telemetry.LoggerTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Realtime.Telemetry.Logger, as: TelemetryLogger

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  describe "logger backend initialization" do
    test "logs on telemetry event" do
      start_link_supervised!({TelemetryLogger, handler_id: "telemetry-logger-test"})

      log =
        capture_log(fn ->
          :telemetry.execute([:realtime, :connections], %{count: 1}, %{tenant: "tenant"})
          :telemetry.execute([:realtime, :rate_counter, :channel, :events], %{count: 1}, %{tenant: "tenant"})
          :telemetry.execute([:realtime, :rate_counter, :channel, :joins], %{count: 1}, %{tenant: "tenant"})
          :telemetry.execute([:realtime, :rate_counter, :channel, :db_events], %{count: 1}, %{tenant: "tenant"})
          :telemetry.execute([:realtime, :rate_counter, :channel, :presence_events], %{count: 1}, %{tenant: "tenant"})
          :telemetry.execute([:realtime, :connections, :output_bytes], %{output_bytes: 100}, %{tenant: "tenant"})
        end)
        |> IO.inspect(label: "log")

      assert log =~ "project=tenant"
      assert log =~ "Billing metrics: [:realtime, :connections]"
      assert log =~ "Billing metrics: [:realtime, :rate_counter, :channel, :events]"
      assert log =~ "Billing metrics: [:realtime, :rate_counter, :channel, :joins]"
      assert log =~ "Billing metrics: [:realtime, :rate_counter, :channel, :db_events]"
      assert log =~ "Billing metrics: [:realtime, :rate_counter, :channel, :presence_events]"
      assert log =~ "Billing metrics: [:realtime, :connections, :output_bytes] output_bytes=100"
    end

    test "ignores events without tenant" do
      start_link_supervised!({TelemetryLogger, handler_id: "telemetry-logger-test"})

      refute capture_log(fn ->
               :telemetry.execute([:realtime, :connections], %{count: 1}, %{})
             end) =~ "Billing metrics: [:realtime, :connections]"
    end
  end
end
