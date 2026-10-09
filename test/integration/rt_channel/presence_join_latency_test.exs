defmodule Realtime.Integration.RtChannel.PresenceJoinLatencyTest do
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [
      %{serializer: Phoenix.Socket.V1.JSONSerializer},
      %{serializer: RealtimeWeb.Socket.V2Serializer}
    ]

  import Generators

  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient

  @moduletag :capture_log
  @join_latency [:realtime, :presence, :join, :latency]

  setup [:checkout_tenant_and_connect, :rls_context]

  setup %{tenant: tenant} do
    id = {__MODULE__, tenant.external_id}

    :telemetry.attach(id, @join_latency, &__MODULE__.handle_telemetry/4, %{pid: self(), tenant: tenant.external_id})

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  test "records one join-latency observation, tagged :cold for a first joiner, when presence is enabled at join",
       %{tenant: tenant, topic: topic, serializer: serializer} do
    tenant_id = tenant.external_id
    topic = "realtime:#{topic}"
    config = %{presence: %{key: "", enabled: true}, private: false}

    {dave, _} = get_connection(tenant, serializer)
    WebsocketClient.join(dave, topic, %{config: config})

    assert_receive %Message{event: "presence_state", topic: ^topic}, 1_000

    assert_receive {:telemetry, @join_latency, %{latency: latency},
                    %{tenant: ^tenant_id, state: :cold, implementation: :phoenix}},
                   1_000

    assert is_integer(latency) and latency >= 0

    # Presence was already enabled at join, so an ordinary track afterward doesn't trigger
    # another sync at all - nothing extra should be recorded.
    WebsocketClient.send_event(dave, topic, "presence", %{type: "presence", event: "TRACK", payload: %{name: "dave"}})
    assert_receive %Message{event: "presence_diff", topic: ^topic}, 1_000

    refute_receive {:telemetry, @join_latency, _, _}
  end

  test "a track that enables presence after a presence-less join does not record a join latency", %{
    tenant: tenant,
    topic: topic,
    serializer: serializer
  } do
    topic = "realtime:#{topic}"

    {dave, _} = get_connection(tenant, serializer)
    WebsocketClient.join(dave, topic, %{config: %{private: false}})

    refute_receive %Message{event: "presence_state", topic: ^topic}, 200
    refute_receive {:telemetry, @join_latency, _, _}

    WebsocketClient.send_event(dave, topic, "presence", %{type: "presence", event: "TRACK", payload: %{name: "dave"}})

    # The resync proves presence did turn on and push state...
    assert_receive %Message{event: "presence_state", topic: ^topic}, 1_000
    # ...but it must never be counted as a join latency.
    refute_receive {:telemetry, @join_latency, _, _}
  end

  def handle_telemetry(event, measurements, metadata, %{pid: pid, tenant: tenant}) do
    if metadata[:tenant] == tenant, do: send(pid, {:telemetry, event, measurements, metadata})
  end
end
