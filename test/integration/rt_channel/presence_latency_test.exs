defmodule Realtime.Integration.RtChannel.PresenceLatencyTest do
  # Stamping happens in the channel process, so the feature flag is stubbed in Mimic global mode,
  # which needs a synchronous module.
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  use Mimic

  import Generators

  alias Phoenix.Socket.Message
  alias Realtime.FeatureFlags
  alias Realtime.Integration.WebsocketClient

  @moduletag :capture_log
  @latency [:realtime, :presence, :notify, :latency]
  @discarded [:realtime, :presence, :notify, :discarded]

  # String keys, nested maps and lists, mixed scalar types, and "_rt" keys of the user's own at
  # several depths, including one shaped like the metrics envelope.
  @nested_payload %{
    "name" => "dave",
    "_rt" => %{"ts" => 1, "node" => "theirs"},
    "profile" => %{
      "_rt" => "nested",
      "tags" => ["admin", "beta"],
      "address" => %{"city" => "Adelaide", "geo" => %{"lat" => -34.9, "lng" => 138.6}}
    },
    "cursors" => [%{"x" => 1, "y" => 2, "_rt" => nil}, %{"x" => 3, "y" => 4}],
    "online" => true,
    "last_seen" => nil,
    "score" => 42
  }

  setup [:checkout_tenant_and_connect, :rls_context, :set_mimic_global]

  setup %{tenant: tenant} do
    stub(FeatureFlags, :enabled?, fn
      "presence_latency_metric", _tenant -> true
      flag, tenant -> Mimic.call_original(FeatureFlags, :enabled?, [flag, tenant])
    end)

    id = {__MODULE__, tenant.external_id}

    :telemetry.attach_many(id, [@latency, @discarded], &__MODULE__.handle_telemetry/4, %{
      pid: self(),
      tenant: tenant.external_id
    })

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  test "measures every other member's notification and never leaks the envelope", %{
    tenant: tenant,
    topic: topic,
    serializer: serializer
  } do
    tenant_id = tenant.external_id
    topic = "realtime:#{topic}"
    parent = self()
    config = %{presence: %{key: "", enabled: true}, private: false}

    # Alice and Bob are already present; Dave is the one tracking. Their frames are tagged so the
    # three mailboxes don't collide.
    {alice, bob} =
      {connect_client(tenant, serializer, spawn_link(fn -> forward_frames(parent, :alice) end)),
       connect_client(tenant, serializer, spawn_link(fn -> forward_frames(parent, :bob) end))}

    {dave, _} = get_connection(tenant, serializer)

    for socket <- [alice, bob, dave], do: WebsocketClient.join(socket, topic, %{config: config})
    assert_receive {:alice, %Message{event: "presence_state", topic: ^topic}}, 1_000
    assert_receive {:bob, %Message{event: "presence_state", topic: ^topic}}, 1_000
    assert_receive %Message{event: "presence_state", topic: ^topic}, 1_000

    # Track: one observation each for Alice, Bob and Dave's own notification.
    WebsocketClient.send_event(dave, topic, "presence", %{type: "presence", event: "TRACK", payload: %{name: "dave"}})

    assert_receive {:alice, %Message{event: "presence_diff", payload: %{"joins" => joins}, topic: ^topic}}, 1_000
    assert_receive {:bob, %Message{event: "presence_diff", payload: %{"joins" => ^joins}, topic: ^topic}}, 1_000
    assert_receive %Message{event: "presence_diff", payload: %{"joins" => ^joins}, topic: ^topic}, 1_000
    assert [%{"name" => "dave"} = meta] = joins |> Map.values() |> hd() |> Map.fetch!("metas")
    refute Map.has_key?(meta, "_rt")

    for _ <- 1..3 do
      assert_receive {:telemetry, @latency, %{latency: latency},
                      %{tenant: ^tenant_id, action: :track, origin: :local, path: :fastlane, implementation: :phoenix}},
                     1_000

      assert is_integer(latency) and latency >= 0
    end

    refute_receive {:telemetry, _, _, _}

    # Update: the diff carries a join and a leave; neither leaks, and each member is measured again.
    WebsocketClient.send_event(dave, topic, "presence", %{
      type: "presence",
      event: "TRACK",
      payload: %{name: "dave", mood: "ok"}
    })

    assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins, "leaves" => leaves}, topic: ^topic},
                   1_000

    assert [joined] = joins |> Map.values() |> hd() |> Map.fetch!("metas")
    assert [left] = leaves |> Map.values() |> hd() |> Map.fetch!("metas")
    refute Map.has_key?(joined, "_rt")
    refute Map.has_key?(left, "_rt")
    assert_receive {:alice, %Message{event: "presence_diff", topic: ^topic}}, 1_000
    assert_receive {:bob, %Message{event: "presence_diff", topic: ^topic}}, 1_000

    for _ <- 1..3 do
      assert_receive {:telemetry, @latency, _, %{tenant: ^tenant_id, action: :update, origin: :local}}, 1_000
    end

    refute_receive {:telemetry, _, _, _}
  end

  test "a nested payload reaches every member and a late joiner intact, with only the envelope removed", %{
    tenant: tenant,
    topic: topic,
    serializer: serializer
  } do
    tenant_id = tenant.external_id
    topic = "realtime:#{topic}"
    parent = self()
    config = %{presence: %{key: "", enabled: true}, private: false}

    alice = connect_client(tenant, serializer, spawn_link(fn -> forward_frames(parent, :alice) end))
    {dave, _} = get_connection(tenant, serializer)

    for socket <- [alice, dave], do: WebsocketClient.join(socket, topic, %{config: config})
    assert_receive {:alice, %Message{event: "presence_state", topic: ^topic}}, 1_000
    assert_receive %Message{event: "presence_state", topic: ^topic}, 1_000

    WebsocketClient.send_event(dave, topic, "presence", %{type: "presence", event: "TRACK", payload: @nested_payload})

    # The diff carries the payload exactly as sent, plus phx_ref, for both the fastlane and the sender.
    assert_receive {:alice, %Message{event: "presence_diff", payload: %{"joins" => joins}, topic: ^topic}}, 1_000
    assert_receive %Message{event: "presence_diff", payload: %{"joins" => ^joins}, topic: ^topic}, 1_000
    assert [meta] = joins |> Map.values() |> hd() |> Map.fetch!("metas")
    assert Map.delete(meta, "phx_ref") == @nested_payload

    for _ <- 1..2 do
      assert_receive {:telemetry, @latency, _, %{tenant: ^tenant_id, action: :track, origin: :local}}, 1_000
    end

    # A late joiner reads the stored meta back through presence_state, stripped the same way.
    erin = connect_client(tenant, serializer, spawn_link(fn -> forward_frames(parent, :erin) end))
    WebsocketClient.join(erin, topic, %{config: config})

    assert_receive {:erin, %Message{event: "presence_state", payload: state, topic: ^topic}}, 1_000
    assert [meta] = state |> Map.values() |> hd() |> Map.fetch!("metas")
    assert Map.delete(meta, "phx_ref") == @nested_payload
  end

  defp connect_client(tenant, serializer, inbox) do
    {:ok, token} = token_valid(tenant, "anon", %{})
    {:ok, socket} = WebsocketClient.connect(inbox, uri(tenant, serializer), serializer, [{"x-api-key", token}])
    socket
  end

  defp forward_frames(parent, tag) do
    receive do
      frame -> send(parent, {tag, frame})
    end

    forward_frames(parent, tag)
  end

  def handle_telemetry(event, measurements, metadata, %{pid: pid, tenant: tenant}) do
    if metadata[:tenant] == tenant, do: send(pid, {:telemetry, event, measurements, metadata})
  end
end
