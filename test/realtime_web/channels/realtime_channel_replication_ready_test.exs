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

  test "pushes the system message when the syn ready broadcast arrives after join", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:error, :not_connected} end)

    assert {:ok, _, _} = join(tenant)

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 200

    signal_ready(tenant, self())

    assert_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 500
  end

  test "ignores syn ready broadcasts without a replication connection", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:error, :not_connected} end)

    assert {:ok, _, _} = join(tenant)

    signal_ready(tenant, nil)

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 300
  end

  test "notifies at most once and stops listening after the first signal", %{tenant: tenant} do
    stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, self()} end)
    stub(Connect, :replication_status, fn _ -> {:ok, self()} end)

    assert {:ok, _, _} = join(tenant)

    assert_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 500

    signal_ready(tenant, self())

    refute_receive %Socket.Message{event: "system", payload: %{message: "Replication connection established"}}, 300
  end

  defp join(tenant) do
    jwt = generate_jwt_token(tenant)
    {:ok, socket} = connect(UserSocket, %{}, conn_opts(tenant, jwt))
    subscribe_and_join(socket, "realtime:test", %{"config" => %{}})
  end

  defp signal_ready(tenant, replication_conn) do
    RealtimeWeb.Endpoint.local_broadcast(
      Connect.syn_topic(tenant.external_id),
      "ready",
      %{pid: self(), conn: self(), replication_conn: replication_conn}
    )
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
