defmodule Beacon.Adapter do
  @moduledoc """
  Behaviour module for Beacon messaging adapters.
  """

  @doc "Register the current process to receive messages for the given scope"
  @callback register(scope :: atom) :: :ok

  @doc "Broadcast a message to all nodes in the given scope"
  @callback broadcast(scope :: atom, message :: term) :: any

  @doc "Broadcast a message to specific nodes in the given scope"
  @callback broadcast(scope :: atom, [node], message :: term) :: any

  @doc "Send a message to a specific node in the given scope"
  @callback send(scope :: atom, node, message :: term) :: any
end
