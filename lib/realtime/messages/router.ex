defmodule Realtime.Messages.Router do
  @moduledoc """
  Hands the messages that `Realtime.Messages.persist/6` sends from other nodes to the producer of their
  database connection, see "Persistence" in `Realtime.Messages`.

  Each node runs `:broadcast_pool_size` routers, like the `Realtime.GenRpcPubSub` workers. Senders abcast to
  the router `name/1` picks for the topic, with the topic as the gen_rpc key, so one gen_rpc client and one
  router carry each topic, which keeps its messages in order.
  """
  use GenServer

  alias Realtime.Messages

  @spec name(String.t()) :: atom()
  def name(topic) do
    routers = :persistent_term.get(__MODULE__)
    elem(routers, :erlang.phash2(topic, tuple_size(routers)))
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, type: :supervisor, start: {__MODULE__, :start_pool, [Keyword.fetch!(opts, :pool_size)]}}
  end

  @spec start_pool(pos_integer()) :: Supervisor.on_start()
  def start_pool(pool_size) do
    routers = for i <- 1..pool_size, do: :"#{__MODULE__}_#{i}"
    :persistent_term.put(__MODULE__, List.to_tuple(routers))
    children = for router <- routers, do: %{id: router, start: {__MODULE__, :start_link, [router]}}
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_info({:persist, conn, tenant_id, entry, caller}, state) do
    Messages.enqueue(conn, tenant_id, entry, caller)
    {:noreply, state}
  end
end
