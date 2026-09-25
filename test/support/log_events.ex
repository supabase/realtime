defmodule LogEvents do
  @moduledoc """
  Forwards every `:logger` event's level and metadata to the test process that installed the handler.

  `capture_log/1` renders only metadata with a `String.Chars` implementation, so a context map or an
  origin map never shows up in it. This delivers the raw event instead:

      setup :capture_log_events

      assert_receive {:log_event, :error, %{error_code: "UnableToReplayMessages"} = meta}

  The handler is global, so match on something specific to the test, such as the tenant id.
  """

  @spec capture_log_events(map()) :: :ok
  def capture_log_events(_context \\ %{}) do
    id = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{config: self()})
    ExUnit.Callbacks.on_exit(fn -> :logger.remove_handler(id) end)
    :ok
  end

  @doc false
  def log(%{level: level, meta: meta}, %{config: pid}), do: send(pid, {:log_event, level, meta})
end
