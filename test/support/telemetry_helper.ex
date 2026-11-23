defmodule TelemetryHelper do
  @moduledoc """
  Helpers for tests that use `:telemetry_test.attach_event_handlers/2`.
  """

  @doc """
  Removes the messages of `event` from the mailbox of the caller, and returns them in the order
  that they arrived, as `{measurements, metadata}`.

  `ref` is the return value of `:telemetry_test.attach_event_handlers/2`. The function does not
  wait. A handler runs in the process that emits the event, so the messages of an event that the
  caller emitted are in the mailbox when the emit returns.
  """
  @spec drain(reference(), [atom()]) :: [{map(), map()}]
  def drain(ref, event) do
    Stream.repeatedly(fn ->
      receive do
        {^event, ^ref, measurements, metadata} -> {measurements, metadata}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end
end
