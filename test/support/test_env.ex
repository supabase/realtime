defmodule TestEnv do
  @moduledoc false
  # Host-global resources a test run binds or registers: TCP ports, EPMD node
  # names and docker container names. Everything is derived from env so two
  # runs (different worktrees, or a run alongside a dev server) never collide.
  # Defaults reproduce the values that were hardcoded before.

  alias Realtime.Env

  @peer_http_base 4012
  @peer_gen_rpc_base 16_970
  @tenant_db_port_range "6500-9000"
  @container_prefix "realtime-test-"
  @container_suffix_length 12

  # Every peer a test starts owns one slot in both peer port blocks, so a node's HTTP and
  # gen_rpc ports stay consistent and no test has to know the arithmetic. The two region
  # clusters hold separate slots so neither reuses a port the other is still releasing.
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

  @spec node_name() :: node()
  def node_name, do: :"main#{Env.get_binary("MIX_TEST_PARTITION", "")}#{node_suffix()}@127.0.0.1"

  @spec peer_name(atom() | charlist() | binary()) :: atom() | charlist() | binary()
  def peer_name(name) do
    case node_suffix() do
      "" -> name
      suffix -> :"#{name}#{suffix}"
    end
  end

  @spec peer_node(atom() | charlist() | binary()) :: node()
  def peer_node(name), do: :"#{peer_name(name)}@127.0.0.1"

  @spec peer_http_port(atom()) :: pos_integer()
  def peer_http_port(peer \\ :default), do: Env.get_integer("TEST_PEER_PORT_BASE", @peer_http_base) + slot!(peer)

  @spec peer_gen_rpc_port(atom()) :: pos_integer()
  def peer_gen_rpc_port(peer \\ :default),
    do: Env.get_integer("TEST_PEER_GEN_RPC_PORT_BASE", @peer_gen_rpc_base) + slot!(peer)

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

  @spec tenant_db_port_range() :: Range.t()
  def tenant_db_port_range do
    value = Env.get_binary("TEST_TENANT_DB_PORT_RANGE", @tenant_db_port_range)

    with [first, last] <- String.split(value, "-", parts: 2),
         {first, ""} <- Integer.parse(String.trim(first)),
         {last, ""} <- Integer.parse(String.trim(last)),
         true <- first <= last do
      first..last
    else
      _ ->
        raise ArgumentError,
              ~s(env TEST_TENANT_DB_PORT_RANGE expected "<first>-<last>" with first <= last, got #{inspect(value)})
    end
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

  @spec container_prefix() :: binary()
  def container_prefix, do: Env.get_binary("TEST_CONTAINER_PREFIX", @container_prefix)

  @spec container_suffix_length() :: pos_integer()
  def container_suffix_length, do: @container_suffix_length

  defp node_suffix do
    case Env.get_binary("TEST_NODE_SUFFIX", "") do
      "" -> ""
      suffix -> "_" <> suffix
    end
  end
end
