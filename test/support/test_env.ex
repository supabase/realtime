defmodule TestEnv do
  @moduledoc false
  # The ports and node names this run owns. config/test.exs claims the ports; names carry its
  # run tag, so concurrent runs never collide.

  # One slot per peer, offset from both peer port ranges, so no test has to know the
  # arithmetic. The region clusters hold separate slots so neither reuses the other's port.
  @peer_slots %{
    default: 0,
    us_node: 1,
    ap2_nodeX: 2,
    ap2_nodeY: 3,
    holder_us: 4,
    bystander_us: 5,
    holder_ap: 6,
    bystander_ap: 7,
    rr_int_a: 8,
    rr_int_b: 9,
    rr_int_c: 10,
    bad_tcp: 11
  }

  # Labels this run's databases and containers. Empty for the first run on a machine, which
  # therefore looks exactly like it did before any of this.
  @spec run_tag() :: binary()
  def run_tag, do: Application.fetch_env!(:realtime, :test_run_tag)

  # Node names get the port rather than the tag: they show up inside inspected maps in logs that
  # tests assert on, so they have to stay short.
  @spec node_suffix() :: binary()
  def node_suffix, do: Application.fetch_env!(:realtime, :test_node_suffix)

  # The endpoint port this run claimed, which is also what a later run probes to decide
  # whether this run is still alive.
  @spec http_port() :: pos_integer()
  def http_port, do: Application.fetch_env!(:realtime, :test_http_port)

  @spec node_name() :: node()
  def node_name, do: :"main#{node_suffix()}@127.0.0.1"

  @spec peer_name(atom() | charlist() | binary()) :: atom() | charlist() | binary()
  def peer_name(name) do
    case node_suffix() do
      "" -> name
      tag -> :"#{name}#{tag}"
    end
  end

  @spec peer_node(atom() | charlist() | binary()) :: node()
  def peer_node(name), do: :"#{peer_name(name)}@127.0.0.1"

  @spec peer_http_port(atom()) :: pos_integer()
  def peer_http_port(peer \\ :default),
    do: Application.fetch_env!(:realtime, :test_peer_http_base) + slot!(peer)

  @spec peer_gen_rpc_port(atom()) :: pos_integer()
  def peer_gen_rpc_port(peer \\ :default),
    do: Application.fetch_env!(:realtime, :test_peer_gen_rpc_base) + slot!(peer)

  @spec peers() :: [atom()]
  def peers, do: Map.keys(@peer_slots)

  defp slot!(peer) do
    case Map.fetch(@peer_slots, peer) do
      {:ok, slot} ->
        slot

      :error ->
        raise ArgumentError,
              "unknown peer #{inspect(peer)}: add it to TestEnv's peer slots. Known: #{inspect(Enum.sort(peers()))}"
    end
  end

  # A port with nothing behind it, for tenant fixtures that never open a connection.
  @spec unused_port() :: :inet.port_number()
  def unused_port do
    {:ok, socket} = :gen_tcp.listen(0, [:inet, ip: {0, 0, 0, 0}, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Can a listener still bind this port? Probes the wildcard address with the same
  # reuseaddr the real listeners use, so a port left in TIME_WAIT by a peer that just
  # stopped reads as available while a live listener — ours or another run's — does not.
  # Inherently a snapshot: use it to report a collision, never to allocate a port.
  @spec port_available?(:inet.port_number()) :: boolean()
  def port_available?(port) do
    case :gen_tcp.listen(port, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false]) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _reason} -> false
    end
  end
end
