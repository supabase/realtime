defmodule Integration.NoChannelsTimeoutTest do
  # Changes the global no-channels timeout
  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient

  @config %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
  # Long enough for a test to connect and join before an idle socket is closed
  @timeout 1000

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)

    previous = :persistent_term.get({RealtimeWeb.UserSocket, :no_channel_timeout_in_ms})
    :persistent_term.put({RealtimeWeb.UserSocket, :no_channel_timeout_in_ms}, @timeout)
    on_exit(fn -> :persistent_term.put({RealtimeWeb.UserSocket, :no_channel_timeout_in_ms}, previous) end)

    %{tenant: tenant}
  end

  test "disconnects a socket that never joins a channel", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)

    assert_receive {:close_code, 1001}, @timeout * 2
    assert_receive {:close_reason, "No channels joined"}
    assert_process_down(socket)
  end

  test "disconnects a socket once its last channel is left", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)

    topics =
      for _ <- 1..3 do
        topic = "realtime:#{random_string()}"
        :ok = WebsocketClient.join(socket, topic, %{config: @config})
        assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
        topic
      end

    for topic <- topics do
      :ok = WebsocketClient.leave(socket, topic, %{})
      assert_receive %Message{topic: ^topic, event: "phx_close"}, 500
    end

    assert_receive {:close_code, 1001}, @timeout * 2
    assert_receive {:close_reason, "No channels joined"}
    assert_process_down(socket)
  end

  test "disconnects a socket once its last channel crashes", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500

    [%{pid: channel_pid}] = server_channels(tenant)
    Process.exit(channel_pid, :kill)

    assert_receive %Message{topic: ^topic, event: "phx_error"}, 500
    assert_receive {:close_code, 1001}, @timeout * 2
    assert_receive {:close_reason, "No channels joined"}
    assert_process_down(socket)
  end

  test "gives a full timeout after the last channel leaves, even if the timer fired meanwhile", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500

    # the timer started on connect fires while the channel is open
    Process.sleep(div(@timeout * 3, 2))

    :ok = WebsocketClient.leave(socket, topic, %{})
    assert_receive %Message{topic: ^topic, event: "phx_close"}, 500

    refute_receive {:close_code, _}, div(@timeout, 2)
    assert_receive {:close_code, 1001}, @timeout * 2
    assert_process_down(socket)
  end

  test "gives a full timeout after a rejected duplicate join drops the last channel", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500

    # the timer started on connect is still pending, with at most half a timeout left
    Process.sleep(div(@timeout, 2))

    # rejoining the same topic closes the existing channel, and this join is rejected
    :ok = WebsocketClient.join(socket, topic, %{config: %{@config | private: true}})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500

    # a full timeout from losing the last channel, not what was left of the connect timer
    refute_receive {:close_code, _}, div(@timeout * 3, 4)
    assert_receive {:close_code, 1001}, @timeout * 2
    assert_process_down(socket)
  end

  test "keeps a socket with a joined channel connected", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500

    refute_receive {:close_code, _}, @timeout * 2
    assert Process.alive?(socket)
  end

  test "rejected joins do not count as channels", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)

    :ok = WebsocketClient.join(socket, "realtime:", %{config: @config})
    assert_receive %Message{topic: "realtime:", event: "phx_reply", payload: %{"status" => "error"}}, 500

    assert_receive {:close_code, 1001}, @timeout * 2
    assert_receive {:close_reason, "No channels joined"}
    assert_process_down(socket)
  end

  test "rejected joins do not affect the socket's live channels", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500

    for _ <- 1..5 do
      :ok = WebsocketClient.join(socket, "realtime:", %{config: @config})
      assert_receive %Message{topic: "realtime:", event: "phx_reply", payload: %{"status" => "error"}}, 500
    end

    refute_receive {:close_code, _}, @timeout * 2
    assert Process.alive?(socket)
  end

  defp server_channels(tenant) do
    id = RealtimeWeb.UserSocket.subscribers_id(tenant.external_id)
    [%{pid: pid}] = Enum.filter(Phoenix.Debug.list_sockets(), &(&1.id == id))
    {:ok, channels} = Phoenix.Debug.list_channels(pid)
    channels
  end
end
