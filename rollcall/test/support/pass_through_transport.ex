defmodule Rollcall.Transport.PassThrough do
  @moduledoc """
  A transport for tests that need to choose the origin of each message.

  A test sends `{:deliver, scope, message}` to the tracker. `unwrap/2` returns
  the scope and the message as they are, so the origin stays the pid that the
  test chose. `Rollcall.Transport.InMemory` rewrites the origin.

  The tracker sends no message and publishes no diff through this transport.
  """

  @behaviour Rollcall.Transport

  @impl true
  def init(scope, _opts), do: {:ok, scope}

  @impl true
  def heartbeat(_scope, _message), do: :ok

  @impl true
  def publish(_scope, _partition, _diff), do: :ok

  @impl true
  def unwrap(_scope, {:deliver, scope, message}), do: {:ok, scope, message}
  def unwrap(_scope, _raw), do: :ignore
end
