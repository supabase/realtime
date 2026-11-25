defmodule Realtime.Messages.Router do
  @moduledoc """
  Hands the messages that `Realtime.Messages.persist/6` sends from other nodes to the producer of their
  database connection, see "Persistence" in `Realtime.Messages`.

  Senders abcast to it with the topic as the gen_rpc key, so the messages of a topic arrive in order on one
  gen_rpc client, and it is one process per node, so it keeps that order.
  """
  use GenServer

  alias Realtime.Messages

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_info({:persist, conn, tenant_id, entry, caller}, state) do
    Messages.enqueue(conn, tenant_id, entry, caller)
    {:noreply, state}
  end
end
