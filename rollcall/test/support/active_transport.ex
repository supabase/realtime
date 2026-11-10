defmodule Rollcall.Transport.Active do
  @moduledoc """
  A transport for tests that control whether the transport is active.

  The option of `init/2` is `:active`, the pid of an `Agent` that holds a boolean.
  `active?/1` returns the value of the agent. A test changes the value with
  `Agent.update/2`.

  The transport unwraps a message like `Rollcall.Transport.PassThrough`. It sends no
  heartbeat and publishes no diff.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.PassThrough

  @impl true
  def init(scope, opts), do: {:ok, %{scope: scope, active: Keyword.fetch!(opts, :active)}}

  @impl true
  def heartbeat(_state, _message), do: :ok

  @impl true
  def publish(_state, _partition, _diff), do: :ok

  @impl true
  def active?(%{active: active}), do: Agent.get(active, & &1)

  @impl true
  def unwrap(%{scope: scope}, raw), do: PassThrough.unwrap(scope, raw)
end
