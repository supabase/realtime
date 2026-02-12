defmodule Integration.TrackerTest do
  # Changing the Tracker ETS table
  use RealtimeWeb.ConnCase, async: false

  alias RealtimeWeb.RealtimeChannel.Tracker
  alias Phoenix.Socket.Message
  alias Realtime.Tenants.Connect
  alias Realtime.Integration.WebsocketClient

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    :ets.delete_all_objects(Tracker.table_name())

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)
    %{db_conn: db_conn, tenant: tenant}
  end

  test "tracks and untracks properly channels", %{tenant: tenant} do
    {socket, _} = get_connection(tenant)
    config = %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}

    topics =
      for _ <- 1..10 do
        topic = "realtime:#{random_string()}"
        :ok = WebsocketClient.join(socket, topic, %{config: config})
        assert_receive %Message{topic: ^topic, event: "phx_reply"}, 500
        topic
      end

    for topic <- topics do
      :ok = WebsocketClient.leave(socket, topic, %{})
      assert_receive %Message{topic: ^topic, event: "phx_close"}, 500
    end

    start_supervised!({Tracker, check_interval_in_ms: 100})
    # wait to trigger tracker
    assert_process_down(socket, 1000)
  end

  test "failed connections are present in tracker with counter lower than 0 so they are actioned on by tracker", %{
    tenant: tenant
  } do
    assert [] = Tracker.list_pids()

    {socket, _} = get_connection(tenant)
    config = %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}

    for _ <- 1..10 do
      topic = "realtime:#{random_string()}"
      :ok = WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500
    end

    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 0
  end

  test "failed connections but one succeeds properly tracks", %{tenant: tenant} do
    assert [] = Tracker.list_pids()

    {socket, _} = get_connection(tenant)
    topic = "realtime:#{random_string()}"

    :ok =
      WebsocketClient.join(socket, topic, %{
        config: %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
      })

    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 1

    for _ <- 1..10 do
      topic = "realtime:#{random_string()}"

      :ok =
        WebsocketClient.join(socket, topic, %{
          config: %{broadcast: %{self: true}, private: true, presence: %{enabled: false}}
        })

      assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "error"}}, 500
    end

    topic = "realtime:#{random_string()}"

    :ok =
      WebsocketClient.join(socket, topic, %{
        config: %{broadcast: %{self: true}, private: false, presence: %{enabled: false}}
      })

    assert_receive %Message{topic: ^topic, event: "phx_reply", payload: %{"status" => "ok"}}, 500
    assert [{_pid, count}] = Tracker.list_pids()
    assert count == 2
  end
end
