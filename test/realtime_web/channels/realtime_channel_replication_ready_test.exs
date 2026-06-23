defmodule RealtimeWeb.RealtimeChannelReplicationReadyTest do
  use RealtimeWeb.ChannelCase, async: false
  use Mimic

  alias Phoenix.Socket
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.UserSocket

  setup :set_mimic_global

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    Realtime.Tenants.Cache.update_cache(tenant)
    {:ok, tenant: tenant}
  end

  test "pushes the system message immediately when replication is already established", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:ok, self()} end)

    assert {:ok, _, _} = join(tenant)

    assert_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 500
  end

  test "pushes the system message once replication becomes ready while polling", %{tenant: tenant} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)

    stub(Connect, :replication_status, fn _ ->
      case Agent.get_and_update(counter, fn n -> {n, n + 1} end) do
        n when n < 3 -> {:error, :not_connected}
        _ -> {:ok, self()}
      end
    end)

    assert {:ok, _, _} = join(tenant)

    assert_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 500
  end

  test "does not push while replication is unavailable", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:error, :not_connected} end)

    assert {:ok, _, _} = join(tenant)

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 300
  end

  test "notifies at most once", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:ok, self()} end)

    assert {:ok, _, _} = join(tenant)

    assert_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 500

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 300
  end

  test "shuts down the channel when replication is not established before the timeout", %{tenant: tenant} do
    previous = Application.get_env(:realtime, :replication_ready_timeout)
    Application.put_env(:realtime, :replication_ready_timeout, 50)
    on_exit(fn -> Application.put_env(:realtime, :replication_ready_timeout, previous) end)

    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:error, :not_connected} end)

    assert {:ok, _, socket} = join(tenant)
    ref = Process.monitor(socket.channel_pid)

    assert_receive %Socket.Message{
                     event: "system",
                     payload: %{status: "error", message: "Replication connection was not established in time"}
                   },
                   500

    assert_receive {:DOWN, ^ref, :process, _, _}, 500
  end

  test "does not arm replication readiness notifications unless opted in", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:ok, self()} end)

    jwt = generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    assert {:ok, _, _} = subscribe_and_join(socket, "realtime:test", %{"config" => %{}})

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 300
  end

  defp join(tenant) do
    jwt = generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    subscribe_and_join(socket, "realtime:test", %{"config" => %{"broadcast" => %{"replication_ready" => true}}})
  end

  defp conn_opts(tenant, token) do
    [
      connect_info: %{
        uri: URI.parse("https://#{tenant.external_id}.localhost:4000/socket/websocket"),
        x_headers: [{"x-api-key", token}]
      }
    ]
  end
end
