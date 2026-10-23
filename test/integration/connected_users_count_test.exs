defmodule Integration.ConnectedUsersCountTest do
  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient
  alias Realtime.UsersCounter

  @config %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}

  setup do
    %{tenant: TestTenantDb.checkout_tenant(run_migrations: true)}
  end

  test "a socket stops counting as a user when it leaves its last channel", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    [topic1, topic2] = for _ <- 1..2, do: join!(socket)
    assert users(tenant) == 1

    # Another channel is still open, so the socket stays counted.
    leave!(socket, topic1)
    refute eventually(fn -> users(tenant) == 0 end, retries: 5)

    # The last channel is gone: the slot is free while the socket stays open.
    leave!(socket, topic2)
    assert eventually(fn -> users(tenant) == 0 end)
    assert Process.alive?(socket)

    # Joining again counts the socket again.
    join!(socket)
    assert users(tenant) == 1
  end

  test "a socket stops counting as a user when its last channel crashes", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = join!(socket)
    assert users(tenant) == 1

    [%{pid: channel_pid}] = server_channels(tenant)
    Process.exit(channel_pid, :kill)
    assert_receive %Message{topic: ^topic, event: "phx_error"}, 500

    assert eventually(fn -> users(tenant) == 0 end)
    assert Process.alive?(socket)
  end

  test "a socket stops counting as a user when a rejected duplicate join drops its last channel",
       %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    topic = join!(socket)
    assert users(tenant) == 1

    # Rejoining the same topic closes the existing channel, and this join is rejected.
    :ok = WebsocketClient.join(socket, topic, %{config: %{@config | private: true}})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500

    assert eventually(fn -> users(tenant) == 0 end)
    assert Process.alive?(socket)
  end

  defp users(tenant), do: UsersCounter.tenant_users(tenant.external_id, node())

  defp join!(socket) do
    topic = "realtime:#{random_string()}"
    :ok = WebsocketClient.join(socket, topic, %{config: @config})
    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
    topic
  end

  defp leave!(socket, topic) do
    :ok = WebsocketClient.leave(socket, topic, %{})
    assert_receive %Message{topic: ^topic, event: "phx_close"}, 500
  end

  defp server_channels(tenant) do
    id = RealtimeWeb.UserSocket.subscribers_id(tenant.external_id)
    [%{pid: pid}] = Enum.filter(Phoenix.Debug.list_sockets(), &(&1.id == id))
    {:ok, channels} = Phoenix.Debug.list_channels(pid)
    channels
  end
end
