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

      assert capture_log(fn ->
               :telemetry.execute([:realtime, :connections], %{count: 1}, %{tenant: "tenant"})
             end) =~ "Billing metrics: [:realtime, :connections]"
    end

    test "ignores events without tenant" do
      start_link_supervised!({TelemetryLogger, handler_id: "telemetry-logger-test"})

      refute capture_log(fn ->
               :telemetry.execute([:realtime, :connections], %{count: 1}, %{})
             end) =~ "Billing metrics: [:realtime, :connections]"
    end
  end
end
