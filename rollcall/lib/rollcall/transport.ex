defmodule Rollcall.Transport do
  @moduledoc """
  Defines the interface a `Rollcall.Tracker` uses to send and receive messages.

  This behaviour abstracts away the underlying transport and structure of the messages
  so `Rollcall.Tracker`s can work independently of the messaging and network environment.

  """
  alias Rollcall.Tracker.Messages

  @type heartbeat_message :: Messages.snapshot() | Messages.diff()

  @doc """
  Join is called when a tracker starts.

  Implementations should perform any setup that's needed and return the value that will
  be passed into subsequent transport calls.
  """
  @callback join(scope :: Rollcall.scope(), opts :: Keyword.t()) :: {:ok, t :: any}
  @doc """
  Called to send a heartbeat message.
  """
  @callback heartbeat(t :: any, message :: heartbeat_message()) :: :ok
  @doc """
  Called when a message is received by the tracker.

  The raw message will be passed in, this is the message in the same structure the transport
  sent it. Implementations should "unwrap" that message and return a valid `Rollcall.Tracker.Messages`
  structure.

  If the message is unknown or shouldn't be processed by the tracker, implementations can return `:ignore`.
  """
  @callback unwrap(t :: any, raw :: any) :: {:ok, scope :: Rollcall.scope(), message :: Messages.t()} | :ignore
end
