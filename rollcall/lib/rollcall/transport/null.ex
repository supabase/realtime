defmodule Rollcall.Transport.Null do
  @moduledoc """
  A null transport that sends no messages. 

  You probably don't actually want to use this, but it's the default for now.

  TODO: Should consider replacing this with an erlang distribution version...
  """

  @behaviour Rollcall.Transport

  @impl true
  def init(scope, _opts) do
    {:ok, scope}
  end

  @impl true
  def heartbeat(_scope, _message) do
    :ok
  end

  @impl true
  def unwrap(_scope, _raw) do
    :ignore
  end
end
