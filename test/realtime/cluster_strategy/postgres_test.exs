defmodule Realtime.Cluster.Strategy.PostgresTest do
  use ExUnit.Case

  alias Cluster.Strategy.State
  alias Postgrex.Notifications, as: PN
  alias Realtime.Cluster.Strategy.Postgres

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :auto)
  end

  test "handle_event/4, :internal, :connect is successful" do
    assert {:noreply, state} = Postgres.handle_continue(:connect, libcluster_state())
    assert is_pid(state.meta.conn)
    assert is_pid(state.meta.conn_notif)
  end

  test "notify cluster after start" do
    state = libcluster_state()
    channel_name = Keyword.fetch!(state.config, :channel_name)

    Postgres.start_link([state])

    {:ok, conn_notif} = PN.start_link(state.meta.opts.())
    PN.listen(conn_notif, channel_name)
    node = "#{node()}"
    assert_receive {:notification, _, _, ^channel_name, ^node}, 10_000
  end

  defp libcluster_state() do
    %State{
      topology: [],
      connect: {__MODULE__, :connect, [self()]},
      disconnect: {__MODULE__, :disconnect, [self()]},
      list_nodes: {__MODULE__, :list_nodes, [[]]},
      config: opts(),
      meta: %{
        opts: fn -> opts() end,
        conn: nil,
        conn_notif: nil,
        heartbeat_ref: nil
      }
    }
  end

  defp opts() do
    [
      hostname: "localhost",
      username: "postgres",
      password: "postgres",
      database: "realtime_test",
      port: 5432,
      parameters: [
        application_name: "#{node()}"
      ],
      heartbeat_interval: 5_000,
      node_timeout: 15_000,
      channel_name: "test_channel_name"
    ]
  end
end
