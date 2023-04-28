defmodule Realtime.Cluster.Strategy.Postgres do
  @moduledoc """
  A libcluster strategy that uses Postgres LISTEN/NOTIFY to determine the cluster topology.

  This strategy works by having all nodes in the cluster listen and notify to Postgres notifications
  on the same channel.

  When a node comes online, it will notify the other nodes on the channel by sending a sync message.
  Other nodes that receive this message will immediately send a heartbeat message back to this node.
  Node will acknowledge the heartbeat messages from other nodes and connect to them.

  All nodes will periodically send heartbeat messages to all other nodes. If a node fails to send a heartbeat
  message inside of a certain time interval, it is considered inactive and will be disconnected from the cluster.

  ## Options

  * `hostname` - The hostname of the database server (required)
  * `username` - The username to connect to the database with (required)
  * `password` - The password to connect to the database with (required)
  * `database` - The database to connect to (required)
  * `port` - The port to connect to (required)
  * `parameters` - Additional database parameters, e.g. application_name (optional)
  * `heartbeat_interval` - The interval at which to send heartbeat messages in milliseconds (optional; default: 5_000)
  * `node_timeout` - The interval after which a node is considered inactive in milliseconds (optional; default: 15_000)

  ## Usage

      config :libcluster,
        topologies: [
          postgres: [
            strategy: #{__MODULE__},
            config: [
              hostname: "locahost",
              username: "postgres",
              password: "postgres",
              database: "postgres",
              port: 5432,
              parameters: [
                application_name: "cluster_node_#{node()}"
              ],
              heartbeat_interval: 5_000,
              node_timeout: 15_000
            ]
          ]
        ]
  """

  @behaviour :gen_statem
  use Cluster.Strategy

  alias Cluster.Logger
  alias Cluster.Strategy
  alias Cluster.Strategy.State
  alias Ecto.Adapters.SQL
  alias Postgrex.Notifications, as: PN
  alias Realtime.Repo

  @channel "cluster"

  defmodule MetaState do
    @moduledoc false
    defstruct conn: nil,
              listen_ref: nil,
              inactive_nodes: MapSet.new()
  end

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @state :no_state

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init([%State{config: config} = state]) do
    Process.flag(:trap_exit, true)

    new_config =
      config
      |> Keyword.put_new(:parameters, [])
      |> Keyword.put_new(:heartbeat_interval, 5_000)
      |> Keyword.put_new(:node_timeout, 15_000)

    state = %{
      state
      | config: new_config,
        meta: %MetaState{}
    }

    {:ok, @state, state, {:next_event, :internal, :connect}}
  end

  @impl :gen_statem
  def handle_event(type, content, statem_state, state)

  def handle_event(
        :internal,
        :connect,
        @state,
        %State{config: config, topology: topology} = state
      ) do
    [
      hostname: Keyword.fetch!(config, :hostname),
      username: Keyword.fetch!(config, :username),
      password: Keyword.fetch!(config, :password),
      database: Keyword.fetch!(config, :database),
      port: Keyword.fetch!(config, :port),
      parameters: Keyword.fetch!(config, :parameters)
    ]
    |> PN.start_link()
    |> case do
      {:ok, pid} ->
        Logger.info(topology, "Connected to Postgres database")

        new_state = update_meta_state(state, :conn, pid)

        {:keep_state, new_state, {{:timeout, :listen}, 0, nil}}

      _ ->
        Logger.error(topology, "Failed to connect to Postgres database")

        {:keep_state, state, {{:timeout, :connect}, rand(1_000), nil}}
    end
  end

  def handle_event(
        :internal,
        :listen,
        @state,
        %State{meta: %{conn: conn}, topology: topology} = state
      ) do
    case PN.listen(conn, @channel) do
      {:ok, ref} ->
        Logger.info(topology, "Listening to Postgres notifications on channel #{@channel}")

        new_state = update_meta_state(state, :listen_ref, ref)

        {:keep_state, new_state, {{:timeout, {:notify, :sync}}, 0, nil}}

      _ ->
        Logger.error(
          topology,
          "Failed to listen to Postgres notifications on channel #{@channel}"
        )

        {:keep_state, state, {{:timeout, :listen}, rand(1_000), nil}}
    end
  end

  def handle_event(
        :internal,
        {:notify, notify_event},
        @state,
        %State{config: config, topology: topology} = state
      ) do
    heartbeat_interval = config[:heartbeat_interval]

    message = "#{notify_event}::#{node()}"

    timeout =
      Repo
      |> SQL.query("NOTIFY #{@channel}, '#{message}'", [])
      |> case do
        {:ok, _} ->
          Logger.debug(
            topology,
            "Notified Postgres on channel #{@channel} with message: " <> message
          )

          rand(heartbeat_interval - 1_000, heartbeat_interval + 1_000)

        {:error, _} ->
          Logger.error(
            topology,
            "Failed to notify Postgres on channel #{@channel} with message: " <> message
          )

          rand(1_000)
      end

    {:keep_state, state, {{:timeout, {:notify, :heartbeat}}, timeout, nil}}
  end

  def handle_event(
        :info,
        {:notification, _pid, _ref, _channel, message},
        @state,
        %State{config: config, meta: %{inactive_nodes: inactive_nodes}} = state
      ) do
    [notify_event, node] = String.split(message, "::")
    node = :"#{node}"
    self = node()
    new_inactive_nodes = MapSet.delete(inactive_nodes, node)
    new_state = update_meta_state(state, :inactive_nodes, new_inactive_nodes)
    new_inactive_nodes = disconnect_nodes(new_state)
    new_state = update_meta_state(state, :inactive_nodes, new_inactive_nodes)

    if node != self do
      new_state
      |> connect_node(node)
      |> case do
        :ok ->
          case notify_event do
            "sync" ->
              {:keep_state, new_state, {{:timeout, {:notify, :heartbeat}}, 0, nil}}

            "heartbeat" ->
              {:keep_state, new_state, {{:timeout, {:listen, node}}, config[:node_timeout], nil}}
          end

        :error ->
          {:keep_state, new_state, {{:timeout, {:notify, :sync}}, 0, nil}}
      end
    else
      {:keep_state, new_state}
    end
  end

  def handle_event(
        {:timeout, {:listen, node}},
        nil,
        @state,
        %State{meta: %{inactive_nodes: inactive_nodes}} = state
      ) do
    new_inactive_nodes = MapSet.put(inactive_nodes, node)

    new_inactive_nodes =
      state
      |> update_meta_state(:inactive_nodes, new_inactive_nodes)
      |> disconnect_nodes()

    new_state = update_meta_state(state, :inactive_nodes, new_inactive_nodes)

    {:keep_state, new_state}
  end

  def handle_event({:timeout, event}, nil, @state, state) do
    {:keep_state, state, {:next_event, :internal, event}}
  end

  def handle_event(
        :info,
        {:EXIT, _pid, _reason},
        @state,
        %State{topology: topology} = state
      ) do
    Logger.error(topology, "Postgres notifications connection terminated")

    new_state =
      state
      |> update_meta_state(:conn, nil)
      |> update_meta_state(:listen_ref, nil)

    {:keep_state, new_state, {{:timeout, :connect}, rand(1_000), nil}}
  end

  def handle_event(:terminate, reason, @state, %State{
        meta: %{conn: conn, listen_ref: ref},
        topology: topology
      }) do
    Logger.warn(topology, "Postgres clustering strategy terminating")

    PN.unlisten(conn, ref)

    GenServer.stop(conn, reason, 100)

    {:stop, reason}
  end

  defp connect_node(%State{connect: connect, list_nodes: list_nodes, topology: topology}, node)
       when is_atom(node) do
    Strategy.connect_nodes(
      topology,
      connect,
      list_nodes,
      [node]
    )
    |> case do
      :ok ->
        Logger.debug(topology, "Connected to node: #{node}")
        :ok

      {:error, _} ->
        Logger.error(topology, "Failed to connect to node: #{node}")
        :error
    end
  end

  defp disconnect_nodes(%State{
         disconnect: disconnect,
         list_nodes: list_nodes,
         meta: %{inactive_nodes: inactive_nodes},
         topology: topology
       }) do
    case Strategy.disconnect_nodes(
           topology,
           disconnect,
           list_nodes,
           MapSet.to_list(inactive_nodes)
         ) do
      :ok ->
        Logger.debug(
          topology,
          "Disconnected from inactive nodes: " <> inspect(inactive_nodes)
        )

        MapSet.new()

      {:error, bad_nodes} ->
        new_inactive_nodes =
          Enum.reduce(bad_nodes, MapSet.new(), fn {n, _}, acc -> MapSet.put(acc, n) end)

        Logger.error(
          topology,
          "Failed to disconnect from inactive nodes: " <> inspect(new_inactive_nodes)
        )

        new_inactive_nodes
    end
  end

  defp update_meta_state(%State{meta: %MetaState{} = meta} = state, key, value) do
    %{state | meta: Map.put(meta, key, value)}
  end

  defp rand(max) do
    rand(0, max)
  end

  defp rand(min, max) do
    min..max
    |> Enum.random()
    |> abs()
  end
end
