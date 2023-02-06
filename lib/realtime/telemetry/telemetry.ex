defmodule Realtime.Telemetry do
  @moduledoc """
  Telemetry wrapper
  """

  @doc """
  Dispatches Telemetry events.
  """

  @spec execute([atom, ...], number | map, map) :: :ok
  def execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end
end
