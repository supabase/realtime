defmodule LogForwarder do
  @moduledoc """
  A `:logger` handler that sends every log message to the test process as `{:log, binary}`.

  Use it instead of `ExUnit.CaptureLog.capture_log/1` when the line under test is logged
  *after* the event the test can wait on (e.g. a process logging once it saw a `:DOWN`):
  `capture_log` may return before that line is written, while `assert_receive` waits for it.

      LogForwarder.attach()
      # ...
      assert_receive {:log, "exact log message"}

  Forwards logs from all processes on the node, so match on the full message.
  """

  @doc "Forwards log messages to the calling process until the test exits."
  def attach do
    id = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: %{pid: self()}})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
  end

  @doc false
  def log(%{msg: {:string, msg}}, %{config: %{pid: pid}}), do: send(pid, {:log, IO.chardata_to_string(msg)})
  def log(_event, _config), do: :ok
end
