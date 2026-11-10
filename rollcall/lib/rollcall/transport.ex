defmodule Rollcall.Transport do
  @moduledoc """
  Defines the interface a `Rollcall.Tracker` uses to send and receive messages,
  and to publish the diffs of its view.

  This behaviour abstracts away the underlying transport and structure of the messages
  so `Rollcall.Tracker`s can work independently of the messaging and network environment.

  The tracker holds no subscribers. The transport delivers the diffs to them.
  The transport also tells the tracker whether the node still needs it. See
  `has_interest?/1`.

  """
  alias Rollcall.Tracker.Messages

  @type heartbeat_message :: Messages.snapshot() | Messages.diff()

  @doc """
  init is called when a tracker starts.

  Implementations should perform any setup that's needed and return the value that will
  be passed into subsequent transport calls.
  """
  @callback init(scope :: Rollcall.scope(), opts :: Keyword.t()) :: {:ok, t :: any}
  @doc """
  Called to send a heartbeat message.
  """
  @callback heartbeat(t :: any, message :: heartbeat_message()) :: :ok

  @doc """
  Called to publish a diff of a partition to the subscribers of that partition
  on this node.

  The tracker calls this function in its own process. It calls it after it
  wrote the change to the view, once for each partition that has a change. It
  never passes an empty diff. A subscriber that reads the state after it
  receives a diff finds the change in the state.

  The function returns `:ok`. Any other return crashes the tracker. The tracker
  waits for the function, so an implementation that does slow work hands the
  diff to another process.
  """
  @callback publish(t :: any, partition :: Rollcall.partition(), diff :: Rollcall.partition_diff()) :: :ok
  @doc """
  Called when a message is received by the tracker.

  The raw message will be passed in, this is the message in the same structure the transport
  sent it. Implementations should "unwrap" that message and return a valid `Rollcall.Tracker.Messages`
  structure.

  If the message is unknown or shouldn't be processed by the tracker, implementations can return `:ignore`.
  """
  @callback unwrap(t :: any, raw :: any) :: {:ok, scope :: Rollcall.scope(), message :: Messages.t()} | :ignore

  @doc """
  Called when the grace period of a tracker with no entry ends. Returns `true`
  when the node still needs the tracker, and `false` otherwise.

  The tracker stops when the function returns `false`. It starts the grace
  period again when the function returns `true`.

  Return `true` while a process on this node reads the scope. 

  The tracker calls this function in its own process, once for each grace
  period. The tracker waits for the function, so keep it fast.

  The callback is optional. A transport that does not implement it has no
  interest.
  """
  @callback has_interest?(t :: any) :: boolean()

  @optional_callbacks has_interest?: 1
end
