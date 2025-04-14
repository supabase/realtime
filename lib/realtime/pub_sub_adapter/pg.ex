defmodule Realtime.PubSubAdapter.PG do
  @moduledoc """
  Customized Phoenix PubSub adapter based on `:pg`/`:pg2`.

  It runs on Distributed Erlang and extends the default adapter with tenant-specific optimizations.

  Key features:
  - Broadcasts messages across the cluster
  - For tenant-specific topics ("realtime:postgres:{tenant_id}"), efficiently routes messages
    only to nodes where connections for that tenant exist
  - Uses tenant-specific caching to optimize routing performance
  - Falls back to standard cluster-wide broadcasting when tenant information is unavailable
  """

  @behaviour Phoenix.PubSub.Adapter
  use Supervisor

  @tenant_group_cache Realtime.PubSubAdapter.Cachex

  ## Adapter callbacks

  @impl true
  def node_name(_), do: node()

  @impl true
  def broadcast(adapter_name, "realtime:postgres:" <> tenant_id = topic, message, dispatcher) do
    pids =
      with {:ok, %{} = adapters} <- Cachex.get(@tenant_group_cache, tenant_id),
           pids when not is_nil(pids) <- Map.get(adapters, adapter_name) do
        pids
      else
        _ -> pg_members(group(adapter_name))
      end

    do_broadcast(topic, message, dispatcher, pids)
  end

  def broadcast(adapter_name, topic, message, dispatcher) do
    pids = pg_members(group(adapter_name))
    do_broadcast(topic, message, dispatcher, pids)
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, dispatcher) do
    send({group(adapter_name), node_name}, {:forward_to_local, topic, message, dispatcher})
    :ok
  end

  defp do_broadcast(topic, message, dispatcher, pids) do
    message = forward_to_local(topic, message, dispatcher)

    for pid <- pids, node(pid) != node() do
      send(pid, message)
    end

    :ok
  end

  defp forward_to_local(topic, message, dispatcher) do
    {:forward_to_local, topic, message, dispatcher}
  end

  defp group(adapter_name) do
    groups = :persistent_term.get(adapter_name)
    elem(groups, :erlang.phash2(self(), tuple_size(groups)))
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_members(group) do
      :pg.get_members(Phoenix.PubSub, group)
    end
  else
    defp pg_members(group) do
      :pg2.get_members({:phx, group})
    end
  end

  ## Supervisor callbacks

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    Supervisor.start_link(__MODULE__, {name, adapter_name, pool_size}, name: :"#{adapter_name}_supervisor")
  end

  @impl true
  def init({name, adapter_name, pool_size}) do
    [_ | groups] =
      for number <- 1..pool_size do
        :"#{adapter_name}_#{number}"
      end

    # Use `adapter_name` for the first in the pool for backwards compatability
    # with v2.0 when the pool_size is 1.
    groups = [adapter_name | groups]

    :persistent_term.put(adapter_name, List.to_tuple(groups))

    children =
      for group <- groups do
        Supervisor.child_spec({Phoenix.PubSub.PG2Worker, {name, group}}, id: group)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Phoenix.PubSub.PG2Worker do
  @moduledoc false
  use GenServer

  @doc false
  def start_link({name, group}) do
    GenServer.start_link(__MODULE__, {name, group}, name: group)
  end

  @impl true
  def init({name, group}) do
    :ok = pg_join(group)
    {:ok, name}
  end

  @impl true
  def handle_info({:forward_to_local, topic, message, dispatcher}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, pubsub}
  end

  @impl true
  def handle_info(_, pubsub) do
    {:noreply, pubsub}
  end

  if Code.ensure_loaded?(:pg) do
    defp pg_join(group) do
      :ok = :pg.join(Phoenix.PubSub, group, self())
    end
  else
    defp pg_join(group) do
      namespace = {:phx, group}
      :ok = :pg2.create(namespace)
      :ok = :pg2.join(namespace, self())
      :ok
    end
  end
end
