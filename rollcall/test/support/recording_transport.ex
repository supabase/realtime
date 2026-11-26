defmodule Rollcall.Transport.Recording do
  @moduledoc """
  A transport for tests that need to see the messages that the tracker sends
  with `send_to/3`.

  The option of `init/2` is `:to`, the pid that receives the reports. `send_to/3`
  sends `{:sent_to, node, message}` to that pid.

  The transport unwraps a message like `Rollcall.Transport.PassThrough`. It sends
  no heartbeat and publishes no diff.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.PassThrough

  @impl true
  def init(scope, opts), do: {:ok, %{scope: scope, to: Keyword.fetch!(opts, :to)}}

  @impl true
  def heartbeat(_state, _message), do: :ok

  @impl true
  def send_to(%{to: to}, node, message) do
    send(to, {:sent_to, node, message})
    :ok
  end

  @impl true
  def publish(_state, _partition, _diff), do: :ok

  @impl true
  def unwrap(%{scope: scope}, raw), do: PassThrough.unwrap(scope, raw)
end
