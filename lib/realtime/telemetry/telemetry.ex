defmodule Realtime.Telemetry do
  def execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end
end
