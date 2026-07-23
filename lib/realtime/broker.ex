defmodule Realtime.Broker do
  @moduledoc """
  Behaviour for the inter-node fan-out layer used to broadcast tenant messages
  across the Realtime cluster.

  Implementations provide publish/subscribe semantics scoped by tenant. The
  default implementation is `Realtime.Broker.Syn`, which offloads fan-out onto
  `:syn` process groups instead of calling each peer node via `gen_rpc`.
  """

  @type topic :: String.t()
  @type message :: term()
  @type opts :: keyword()

  @callback child_spec(opts()) :: Supervisor.child_spec()
  @callback publish(topic(), message(), opts()) :: :ok | {:error, term()}
  @callback subscribe(topic(), opts()) :: :ok | {:error, term()}
  @callback unsubscribe(topic()) :: :ok
end
