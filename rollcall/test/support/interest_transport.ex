defmodule Rollcall.Transport.Interest do
  @moduledoc """
  A transport for tests that control the interest of the transport.

  The option of `init/2` is `:interest`, the pid of an `Agent` that holds a boolean.
  `has_interest?/1` returns the value of the agent. A test changes the value with
  `Agent.update/2`.

  The transport unwraps a message like `Rollcall.Transport.PassThrough`. It sends no
  heartbeat and publishes no diff.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.PassThrough

  @impl true
  def init(scope, opts), do: {:ok, %{scope: scope, interest: Keyword.fetch!(opts, :interest)}}

  @impl true
  def heartbeat(_state, _message), do: :ok

  @impl true
  def publish(_state, _partition, _diff), do: :ok

  @impl true
  def has_interest?(%{interest: interest}), do: Agent.get(interest, & &1)

  @impl true
  def unwrap(%{scope: scope}, raw), do: PassThrough.unwrap(scope, raw)
end
