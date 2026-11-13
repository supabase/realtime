defmodule ClusterPresence do
  @moduledoc """
  Helpers for the tests that run presence on several real nodes. `Clustered` starts the nodes.

  The test node is one of the nodes. A client connects to a node with `connect_client/4`, and the
  frames it receives arrive in the mailbox of the test as `{tag, frame}`, so a test can tell which
  client received a frame.
  """

  use TestHelpers

  import ExUnit.Assertions
  import Generators

  alias Ecto.Adapters.SQL.Sandbox
  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient

  # The serializer does not change what a presence test on several nodes checks, so the tests use the
  # default of `Generators.get_connection/3`.
  @serializer Phoenix.Socket.V1.JSONSerializer

  @doc """
  Sets the presence mode of the tenant on every node and waits until each node reports it.

  The flags are tenant overrides, so the function commits them to the database outside the
  sandbox. A write inside the sandbox stays uncommitted, and with such a write the delete of the
  tenant failed when the test ended.
  """
  @spec set_presence_mode(Realtime.Api.Tenant.t(), :phoenix | :shadow | :rollcall, [node()]) :: :ok
  def set_presence_mode(tenant, mode, nodes) do
    flags = Map.merge(tenant.feature_flags, Integrations.presence_flags(mode))

    {:ok, _tenant} =
      Sandbox.unboxed_run(Realtime.Repo, fn ->
        Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{feature_flags: flags})
      end)

    # The cache update of the API is a multicast that can land late, so a node reports the mode
    # when it has the new tenant.
    for node <- nodes do
      assert_eventually(:erpc.call(node, Realtime.Presence, :mode, [tenant.external_id]) == mode)
    end

    :ok
  end

  @doc """
  Connects a client to `node`, joins `topic` with presence enabled and the presence `key`, and waits
  for the `presence_state`. Returns the socket and the payload of the `presence_state`.

  The client sends every frame to the test as `{tag, frame}`. The `node` is `:local` for the test
  node.
  """
  @spec connect_client(Realtime.Api.Tenant.t(), node() | :local, atom(), keyword()) :: {pid(), map()}
  def connect_client(tenant, node, tag, opts) do
    topic = Keyword.fetch!(opts, :topic)
    key = Keyword.fetch!(opts, :key)
    parent = self()

    inbox = spawn_link(fn -> forward_frames(parent, tag) end)
    {:ok, token} = token_valid(tenant, "anon", %{})

    {:ok, socket} =
      WebsocketClient.connect(inbox, uri(tenant, @serializer, port(node)), @serializer, [{"x-api-key", token}])

    config = %{presence: %{key: key, enabled: true}, private: false}
    WebsocketClient.join(socket, topic, %{config: config})
    # The first join of a tenant on a node opens the database connection of the tenant.
    assert_receive {^tag, %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}}, 5_000
    assert_receive {^tag, %Message{event: "presence_state", topic: ^topic, payload: state}}, 5_000

    {socket, state}
  end

  @doc "Sends a `TRACK` with `payload` from the client on `topic`."
  @spec track(pid(), String.t(), map()) :: :ok
  def track(socket, topic, payload) do
    WebsocketClient.send_event(socket, topic, "presence", %{type: "presence", event: "TRACK", payload: payload})
  end

  @doc "Sends an `UNTRACK` from the client on `topic`."
  @spec untrack(pid(), String.t()) :: :ok
  def untrack(socket, topic) do
    WebsocketClient.send_event(socket, topic, "presence", %{type: "presence", event: "UNTRACK"})
  end

  defp port(:local), do: nil
  defp port(node), do: node |> peer_name() |> TestEnv.peer_http_port()

  # The slot name of a peer node.
  defp peer_name(node) do
    Enum.find(TestEnv.peers(), fn name -> TestEnv.peer_node(name) == node end) ||
      raise ArgumentError, "#{inspect(node)} is not a peer node of the test environment"
  end

  defp forward_frames(parent, tag) do
    receive do
      frame -> send(parent, {tag, frame})
    end

    forward_frames(parent, tag)
  end
end
