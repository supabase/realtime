defmodule Realtime.Cluster.Strategy.PostgresTest do
  use ExUnit.Case

  import Mock

  alias Cluster.Strategy.State
  alias Ecto.Adapters.SQL
  alias Postgrex.Notifications, as: PN
  alias Realtime.Cluster.Strategy.Postgres

  def connect(caller, result \\ true, node) do
    send(caller, {:connect, node})
    result
  end

  def disconnect(caller, result \\ true, node) do
    send(caller, {:disconnect, node})
    result
  end

  def list_nodes(nodes) do
    nodes
  end

  @test_node :testhost@testnode
  @state :no_state
  @libcluster_state %State{
    topology: [],
    connect: {__MODULE__, :connect, [self()]},
    disconnect: {__MODULE__, :disconnect, [self()]},
    list_nodes: {__MODULE__, :list_nodes, [[]]},
    config: [
      hostname: "localhost",
      username: "postgres",
      password: "postgres",
      database: "realtime_test",
      port: 5432,
      parameters: [
        application_name: "#{node()}"
      ],
      heartbeat_interval: 5_000,
      node_timeout: 15_000
    ],
    meta: %Postgres.MetaState{conn: nil, listen_ref: nil, inactive_nodes: MapSet.new()}
  }

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Realtime.Repo, :auto)
  end

  test "handle_event/4, :internal, :connect is successful" do
    assert {:keep_state, %State{} = state, {{:timeout, :listen}, 0, nil}} =
             Postgres.handle_event(:internal, :connect, @state, @libcluster_state)

    assert is_pid(state.meta.conn)
  end

  test "handle_event/4, :internal, :connect is unsuccessful" do
    with_mock PN, start_link: fn _ -> {:error, :error} end do
      assert {:keep_state, %State{} = state, {{:timeout, :connect}, timeout, nil}} =
               Postgres.handle_event(:internal, :connect, @state, @libcluster_state)

      assert is_nil(state.meta.conn)
      assert timeout <= 1_000
    end
  end

  test "handle_event/4, :internal, :listen is successful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    assert {:keep_state, %State{} = state, {{:timeout, {:notify, :sync}}, 0, nil}} =
             Postgres.handle_event(:internal, :listen, @state, test_state)

    assert is_reference(state.meta.listen_ref)
  end

  test "handle_event/4, :internal, :listen is unsuccessful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    with_mock PN, listen: fn _, _ -> {:eventually, make_ref()} end do
      assert {:keep_state, %State{} = state, {{:timeout, :listen}, timeout, nil}} =
               Postgres.handle_event(:internal, :listen, @state, test_state)

      assert is_nil(state.meta.listen_ref)
      assert timeout <= 1_000
    end
  end

  test "handle_event/4, :internal, {:notify, :sync} is successful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    assert {:keep_state, %State{}, {{:timeout, {:notify, :heartbeat}}, timeout, nil}} =
             Postgres.handle_event(:internal, {:notify, :sync}, @state, test_state)

    assert timeout >= 4_000
    assert timeout <= 6_000
  end

  test "handle_event/4, :internal, {:notify, :sync} is unsuccessful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    with_mock SQL, query: fn _, _, _ -> {:error, :error} end do
      assert {:keep_state, %State{}, {{:timeout, {:notify, :heartbeat}}, timeout, nil}} =
               Postgres.handle_event(:internal, {:notify, :sync}, @state, test_state)

      assert timeout <= 1_000
    end
  end

  test "handle_event/4, :internal, {:notify, :heartbeat} is successful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    assert {:keep_state, %State{}, {{:timeout, {:notify, :heartbeat}}, timeout, nil}} =
             Postgres.handle_event(:internal, {:notify, :heartbeat}, @state, test_state)

    assert timeout >= 4_000
    assert timeout <= 6_000
  end

  test "handle_event/4, :internal, {:notify, :heartbeat} is unsuccessful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    with_mock SQL, query: fn _, _, _ -> {:error, :error} end do
      assert {:keep_state, %State{}, {{:timeout, {:notify, :heartbeat}}, timeout, nil}} =
               Postgres.handle_event(:internal, {:notify, :heartbeat}, @state, test_state)

      assert timeout <= 1_000
    end
  end

  test "handle_event/4, {:timeout, {:listen, node}} is successful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    assert {:keep_state, %State{}} =
             Postgres.handle_event({:timeout, {:listen, @test_node}}, nil, @state, test_state)
  end

  test "handle_event/4, {:timeout, {:listen, node}} is unsuccessful" do
    {:ok, conn} = PN.start_link(@libcluster_state.config)
    test_state = %{@libcluster_state | meta: %{@libcluster_state.meta | conn: conn}}

    expected_inactive_nodes = MapSet.new([@test_node])

    with_mock Cluster.Strategy,
      disconnect_nodes: fn _, _, _, _ -> {:error, [{@test_node, "reason"}]} end do
      assert {:keep_state,
              %Cluster.Strategy.State{
                meta: %Postgres.MetaState{inactive_nodes: ^expected_inactive_nodes}
              }} =
               Postgres.handle_event({:timeout, {:listen, @test_node}}, nil, @state, test_state)
    end
  end

  test "notify cluster of sync" do
    [
      %State{
        topology: [],
        connect: {__MODULE__, :connect, [self()]},
        disconnect: {__MODULE__, :disconnect, [self()]},
        list_nodes: {__MODULE__, :list_nodes, [[]]},
        config: [
          hostname: "localhost",
          username: "postgres",
          password: "postgres",
          database: "realtime_test",
          port: 5432,
          parameters: [
            application_name: "#{node()}"
          ],
          heartbeat_interval: 5_000,
          node_timeout: 15_000
        ],
        meta: %Postgres.MetaState{conn: nil, listen_ref: nil, inactive_nodes: MapSet.new([])}
      }
    ]
    |> Postgres.start_link()

    {:ok, conn} = Postgrex.start_link(@libcluster_state.config)

    Enum.map(1..100, fn _ ->
      Postgrex.query!(conn, "NOTIFY cluster, 'sync::#{@test_node}'", [])
    end)

    assert_receive {:connect, @test_node}
  end

  test "notify cluster of heartbeat" do
    [
      %State{
        topology: [],
        connect: {__MODULE__, :connect, [self()]},
        disconnect: {__MODULE__, :disconnect, [self()]},
        list_nodes: {__MODULE__, :list_nodes, [[]]},
        config: [
          hostname: "localhost",
          username: "postgres",
          password: "postgres",
          database: "realtime_test",
          port: 5432,
          parameters: [
            application_name: "#{node()}"
          ],
          heartbeat_interval: 5_000,
          node_timeout: 15_000
        ],
        meta: %Postgres.MetaState{conn: nil, listen_ref: nil, inactive_nodes: MapSet.new([])}
      }
    ]
    |> Postgres.start_link()

    {:ok, conn} = Postgrex.start_link(@libcluster_state.config)

    Enum.map(1..100, fn _ ->
      Postgrex.query!(conn, "NOTIFY cluster, 'heartbeat::#{@test_node}'", [])
    end)

    assert_receive {:connect, @test_node}
  end
end
