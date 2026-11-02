defmodule Rollcall.NetworkHelpers do
  @moduledoc """
  Starts trackers that exchange messages through `Rollcall.Transport.InMemory`.

  `start_node/4` starts a tracker on a fake node. Its timer is off, so a test
  sends the ticks. The tests talk to a tracker by pid, because several trackers
  of one scope run in one VM and `Rollcall.Tracker.via/1` allows one.

  A test can also act as a peer. `join_probe/3` joins the test process to the
  network. `receive_message/2` returns the next message that a tracker sent to
  the probe. `send_from_probe/2` sends a message to the trackers. A test can use
  one probe.
  """

  import ExUnit.Assertions

  alias Rollcall.Tracker
  alias Rollcall.Transport.InMemory
  alias Rollcall.Transport.InMemory.Network

  @doc "Starts a network under the test supervisor."
  @spec start_network() :: pid()
  def start_network, do: ExUnit.Callbacks.start_supervised!(Network)

  @doc """
  Starts a tracker for `scope` on the fake node `node`, under the test
  supervisor.

  `opts` are options of `Rollcall.Tracker.start_link/1`. They replace the
  defaults: the in-memory transport on `network`, `heartbeat_period: :manual` and
  a name that is unique for the scope and the node. The option `:id` sets the id
  of the child, for a test that starts a second tracker for one node.
  """
  @spec start_node(Rollcall.scope(), pid(), node(), keyword()) :: pid()
  def start_node(scope, network, node, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, {scope, node})

    opts =
      Keyword.merge(
        [
          name: :"tracker-#{scope}-#{node}",
          transport: {InMemory, network: network, node: node},
          heartbeat_period: :manual
        ],
        opts
      )

    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({Tracker, {scope, opts}}, id: id))
  end

  @doc "Stops the supervised tracker with `id`, as a supervisor shutdown does."
  @spec stop_node(term()) :: :ok
  def stop_node(id), do: ExUnit.Callbacks.stop_supervised!(id)

  @doc "Kills `tracker` and waits until it is dead. The tracker runs no callback."
  @spec kill_node(pid()) :: :ok
  def kill_node(tracker) do
    ref = Process.monitor(tracker)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}
    :ok
  end

  @doc """
  Starts a process that stands for a client, and returns its pid. The process
  is killed when the test ends.
  """
  @spec start_client() :: pid()
  def start_client do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  @doc "Tracks an entry in `tracker`, and returns the ref."
  @spec track(pid(), pid(), Rollcall.partition(), Rollcall.key(), Rollcall.meta()) :: Rollcall.ref()
  def track(tracker, client, partition, key, meta \\ %{}) do
    {:ok, ref} = GenServer.call(tracker, {:track, client, partition, key, meta})
    ref
  end

  @doc "Removes the entry of `client` for `key` in `partition` from `tracker`."
  @spec untrack(pid(), pid(), Rollcall.partition(), Rollcall.key()) :: :ok
  def untrack(tracker, client, partition, key) do
    :ok = GenServer.call(tracker, {:untrack, client, partition, key})
  end

  @doc "Returns the state of `tracker`, in the shape of `Rollcall.Tracker.get_state/1`."
  @spec tracker_state(pid()) :: Tracker.inspected_state()
  def tracker_state(tracker), do: GenServer.call(tracker, :get_state)

  @doc "Returns the peer record of `tracker` for `node`, or `nil`."
  @spec peer(pid(), node()) :: Rollcall.Tracker.Peer.t() | nil
  def peer(tracker, node), do: tracker |> tracker_state() |> Map.fetch!(:peers) |> Map.get(node)

  @doc "Sends `:tick` to `tracker` and waits until the tracker handled it."
  @spec tick(pid(), pos_integer()) :: :ok
  def tick(tracker, times \\ 1) do
    for _ <- 1..times, do: send(tracker, :tick)
    sync(tracker)
  end

  @doc "Returns after `tracker` handled every message that reached it before the call."
  @spec sync(pid()) :: :ok
  def sync(tracker) do
    :sys.get_state(tracker)
    :ok
  end

  @doc "Joins the test process to `scope` on `network` as the fake node `node`. Returns the transport state."
  @spec join_probe(pid(), Rollcall.scope(), node()) :: term()
  def join_probe(network, scope, node) do
    {:ok, transport} = InMemory.init(scope, network: network, node: node)
    transport
  end

  @doc "Sends `message` from the probe to the trackers of its scope."
  @spec send_from_probe(term(), term()) :: :ok
  def send_from_probe(probe, message), do: InMemory.heartbeat(probe, message)

  @doc """
  Returns the next message that a tracker sent to the probe. The origin of the
  message is on the node of the sender. Fails the test after `timeout`
  milliseconds.
  """
  @spec receive_message(term(), timeout()) :: term()
  def receive_message(probe, timeout \\ 1_000) do
    receive do
      {:in_memory, _, _, _} = raw ->
        {:ok, _scope, message} = InMemory.unwrap(probe, raw)
        message
    after
      timeout -> flunk("No message from a tracker within #{timeout} ms")
    end
  end
end
