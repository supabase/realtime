defmodule Rollcall.Transport.PublishProbe do
  @moduledoc """
  A transport for tests that need to see the view at the moment of a
  publication.

  The options of `init/2` are `:to`, the pid that receives the reports, and
  `:rollcall`, the name of the instance of the tracker. `publish/3` runs in
  the tracker process. It reads the partition with `Rollcall.state/3` and sends
  `{:published, partition, diff, state}` to the `:to` pid. `state` is what the
  view held when the tracker called `publish/3`.

  The transport unwraps a message like `Rollcall.Transport.PassThrough`, and it
  sends no heartbeat.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.PassThrough

  @impl true
  def init(scope, opts) do
    {:ok, %{scope: scope, to: Keyword.fetch!(opts, :to), rollcall: Keyword.fetch!(opts, :rollcall)}}
  end

  @impl true
  def heartbeat(_state, _message), do: :ok

  @impl true
  def publish(%{scope: scope, to: to, rollcall: rollcall}, partition, diff) do
    send(to, {:published, partition, diff, Rollcall.state(rollcall, scope, partition)})
    :ok
  end

  @impl true
  defdelegate unwrap(state, raw), to: PassThrough
end
