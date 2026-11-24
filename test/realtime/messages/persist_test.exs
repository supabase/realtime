defmodule Realtime.Messages.PersistTest do
  # The telemetry handlers and capture_log below see the events and logs of every test
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Messages.Producer
  alias Realtime.Tenants.Repo

  setup context do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)
    create_messages_partitions(conn, Date.utc_today() |> Date.add(-1), Date.utc_today() |> Date.add(1))
    start_supervised!({Producer, db_conn: conn, tenant_id: tenant.external_id, config: Map.get(context, :config, [])})
    test_pid = self()

    on_exit(fn -> :telemetry.detach({__MODULE__, test_pid}) end)

    :telemetry.attach_many(
      {__MODULE__, test_pid},
      [[:realtime, :tenants, :persist, :flush], [:realtime, :tenants, :persist, :dropped]],
      fn event, measurements, metadata, _ -> send(test_pid, {:telemetry, event, measurements, metadata}) end,
      nil
    )

    %{conn: conn, tenant_id: tenant.external_id}
  end

  describe "persist/6" do
    test "sends the id of the stored message to reply_to", %{conn: conn, tenant_id: tenant_id} do
      topic = random_string()

      assert {:ok, id} = persist_and_wait(conn, tenant_id, topic, "event", {:json, %{"a" => "b"}})

      assert {:ok,
              [
                %Message{
                  id: ^id,
                  topic: ^topic,
                  event: "event",
                  payload: %{"a" => "b"},
                  binary_payload: nil,
                  extension: :broadcast,
                  private: true,
                  skip_broadcast: true
                }
              ]} = Repo.all(conn, Message, Message)
    end

    test "stores a raw json payload", %{conn: conn, tenant_id: tenant_id} do
      assert {:ok, id} =
               persist_and_wait(conn, tenant_id, "t", "e", {:json, Jason.Fragment.new(~s({"x":1}))})

      assert {:ok, [%Message{id: ^id, payload: %{"x" => 1}, binary_payload: nil}]} = Repo.all(conn, Message, Message)
    end

    test "stores a binary payload", %{conn: conn, tenant_id: tenant_id} do
      assert {:ok, id} = persist_and_wait(conn, tenant_id, "t", "e", {:binary, <<0, 1, 2>>})

      assert {:ok, [%Message{id: ^id, payload: nil, binary_payload: <<0, 1, 2>>}]} = Repo.all(conn, Message, Message)
    end

    test "stores expires_at", %{conn: conn, tenant_id: tenant_id} do
      expires_at = ~N[2030-01-01 00:00:00.000000]

      assert {:ok, id} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}}, expires_at: expires_at)

      assert {:ok, [%Message{id: ^id, expires_at: ^expires_at}]} = Repo.all(conn, Message, Message)
    end

    test "stores no expires_at when none is given", %{conn: conn, tenant_id: tenant_id} do
      assert {:ok, id} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})

      assert {:ok, [%Message{id: ^id, expires_at: nil}]} = Repo.all(conn, Message, Message)
    end

    @tag config: [flush_interval_ms: 60_000]
    test "writes a message right away when idle", %{conn: conn, tenant_id: tenant_id} do
      assert {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
    end

    @tag config: [flush_interval_ms: 60_000]
    test "waits flush_interval_ms before the next write", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)

      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      refute_receive {:telemetry, [:realtime, :tenants, :persist, :flush], _, _}, 200
      assert count_messages(conn) == 1
    end

    @tag config: [max_batch_size: 100, flush_interval_ms: 60_000]
    test "writes a burst in batches of max_batch_size", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      for i <- 1..1_000, do: :ok = Messages.persist(conn, tenant_id, "burst", "e", {:json, %{"i" => i}})

      flushes = collect_flushes(1_000)

      assert length(flushes) == 10
      assert Enum.all?(flushes, &(&1.count == 100 and &1.inserted == 100))
      assert count_messages(conn) == 1_001
    end

    @tag config: [max_batch_size: 100, flush_interval_ms: 60_000]
    test "gives messages strictly increasing inserted_at in send order", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      for i <- 1..1_000, do: :ok = Messages.persist(conn, tenant_id, "order", "e", {:json, %{"i" => i}})

      assert length(collect_flushes(1_000)) == 10

      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT (payload->>'i')::int, inserted_at FROM realtime.messages WHERE topic = 'order' ORDER BY inserted_at",
          []
        )

      assert Enum.map(rows, &hd/1) == Enum.to_list(1..1_000)
      assert rows |> Enum.map(&List.last/1) |> Enum.uniq() |> length() == 1_000
    end

    @tag config: [max_batch_bytes: 1_000, max_batch_size: 1_000, flush_interval_ms: 1_000]
    test "flushes before a batch goes over max_batch_bytes", %{conn: conn, tenant_id: tenant_id} do
      payload = {:json, Jason.Fragment.new(~s({"data":"#{String.duplicate("a", 290)}"}))}
      start_flush_interval(conn, tenant_id)

      for _ <- 1..9, do: :ok = Messages.persist(conn, tenant_id, "bytes", "e", payload)

      flushes = collect_flushes(9)

      assert Enum.map(flushes, & &1.count) == [3, 3, 3]
      assert Enum.all?(flushes, &(&1.bytes <= 1_000))
    end

    @tag config: [max_pending: 1, flush_interval_ms: 60_000]
    test "counts a rejected message as dropped", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
      {:error, :persistence_buffer_full} = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      assert_receive {:telemetry, [:realtime, :tenants, :persist, :dropped], %{count: 1},
                      %{reason: :persistence_buffer_full}}
    end

    @tag config: [max_pending: 5, flush_interval_ms: 60_000]
    test "rejects messages once max_pending messages are waiting", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)

      results = for _ <- 1..10, do: Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      assert Enum.count(results, &(&1 == :ok)) == 5
      assert Enum.count(results, &(&1 == {:error, :persistence_buffer_full})) == 5
    end

    @tag config: [max_pending: 2, max_batch_size: 1, flush_interval_ms: 60_000]
    test "counts the batch being written as waiting", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      consumer = :sys.get_state(producer(conn)).state.consumer
      :sys.suspend(consumer)

      results = for _ <- 1..3, do: Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      assert results == [:ok, :ok, {:error, :persistence_buffer_full}]
      :sys.resume(consumer)
      assert_eventually count_messages(conn) == 3, interval: 10
    end

    @tag config: [max_pending_bytes: 100, flush_interval_ms: 1_000]
    test "rejects messages once max_pending_bytes are waiting", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      payload = {:json, Jason.Fragment.new(~s({"data":"#{String.duplicate("a", 30)}"}))}

      results = for _ <- 1..3, do: Messages.persist(conn, tenant_id, "t", "e", payload)

      assert results == [:ok, :ok, {:error, :persistence_buffer_full}]
      assert [%{count: 2, bytes: 82}] = collect_flushes(2)
    end

    @tag config: [flush_interval_ms: 10]
    test "persists every message, with no limit per second", %{conn: conn, tenant_id: tenant_id} do
      for i <- 1..1_500, do: :ok = Messages.persist(conn, tenant_id, "rate", "e", {:json, %{"i" => i}})

      collect_flushes_until_idle()

      assert count_messages(conn) == 1_500
    end

    @tag config: [max_pending: 1, drops_report_interval_ms: 60_000, flush_interval_ms: 60_000]
    test "logs a summary of messages that were not persisted", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      pid = producer(conn)

      log =
        capture_log(fn ->
          for _ <- 1..5, do: Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
          send(pid, :report_drops)
          :sys.get_state(pid)
        end)

      assert log =~ "PersistenceLimitReached: 4 messages were broadcast but not persisted: persistence_buffer_full"
    end

    @tag config: [
           max_batch_size: 5,
           flush_interval_ms: 60_000,
           breaker_threshold: 1,
           breaker_cooldown_ms: 60_000,
           drops_report_interval_ms: 60_000
         ]
    test "logs failed writes to the project", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      pid = producer(conn)
      Postgrex.query!(conn, "DROP TABLE realtime.messages_#{partition_suffix()}", [])

      log =
        capture_log([format: "$metadata$message\n", metadata: [:project]], fn ->
          for _ <- 1..5, do: :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
          assert_eventually :sys.get_state(pid).state.drops == %{persistence_failed: 5}, interval: 10
          send(pid, :report_drops)
          :sys.get_state(pid)
        end)

      assert log =~ "project=#{tenant_id} UnableToPersistMessage: %Postgrex.Error"
      assert log =~ "project=#{tenant_id} PersistenceUnavailable: Persistence paused after 1 failed write\n"

      assert log =~
               "project=#{tenant_id} UnableToPersistMessage: 5 messages were broadcast but not persisted: persistence_failed"
    end

    @tag config: [
           max_batch_size: 5,
           flush_interval_ms: 60_000,
           breaker_threshold: 1,
           breaker_cooldown_ms: 60_000,
           drops_report_interval_ms: 60_000
         ]
    test "keeps the queued messages while writes are paused", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      pid = producer(conn)
      Postgrex.query!(conn, "DROP TABLE realtime.messages_#{partition_suffix()}", [])

      for _ <- 1..15, do: :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      assert_eventually :sys.get_state(pid).state.drops == %{persistence_failed: 5}, interval: 10
      assert :sys.get_state(pid).state.count == 10
    end

    @tag config: [flush_interval_ms: 60_000]
    test "logs the queued messages when the database connection stops", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      for _ <- 1..3, do: :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
      pid = producer(conn)
      ref = Process.monitor(pid)

      log =
        capture_log([format: "$metadata$message\n", metadata: [:project]], fn ->
          GenServer.stop(conn)
          assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
        end)

      assert log =~
               "project=#{tenant_id} UnableToPersistMessage: 3 messages were broadcast but not persisted: persistence_unavailable"
    end

    @tag config: [flush_interval_ms: 1_000]
    test "an invalid json payload only fails its own message", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{"ok" => 1}})
      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, Jason.Fragment.new("not json")})
      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{"ok" => 2}})

      assert [%{count: 3, inserted: 2}] = collect_flushes(3)
      assert {:ok, messages} = Repo.all(conn, Message, Message)

      assert messages |> Enum.map(& &1.payload) |> Enum.reject(&(&1 == %{})) |> Enum.sort() == [
               %{"ok" => 1},
               %{"ok" => 2}
             ]
    end

    @tag config: [breaker_threshold: 1, breaker_cooldown_ms: 500]
    test "pauses writes for breaker_cooldown_ms after failed writes", %{conn: conn, tenant_id: tenant_id} do
      fail_write(conn, tenant_id)

      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      refute_receive {:telemetry, [:realtime, :tenants, :persist, :flush], _, _}, 300
    end

    @tag config: [breaker_threshold: 1, breaker_cooldown_ms: 500]
    test "writes the queued messages once breaker_cooldown_ms has passed", %{conn: conn, tenant_id: tenant_id} do
      fail_write(conn, tenant_id)

      :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

      assert_receive {:telemetry, [:realtime, :tenants, :persist, :flush], %{count: 1, inserted: 1}, _}, 1_000
    end

    test "writes after the last inserted_at when the clock is behind it", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      last_inserted_at = NaiveDateTime.utc_now() |> NaiveDateTime.add(1, :hour)
      :sys.replace_state(consumer(conn), &put_in(&1.state.last_inserted_at, last_inserted_at))

      {:ok, id} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})

      assert {:ok, %Message{inserted_at: inserted_at}} = Repo.one(conn, from(m in Message, where: m.id == ^id), Message)
      assert inserted_at == NaiveDateTime.add(last_inserted_at, 1, :microsecond)
    end

    @tag config: [hibernate_after: 50]
    test "hibernates when idle", %{conn: conn, tenant_id: tenant_id} do
      {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})

      assert_eventually hibernating?(producer(conn)), interval: 10
    end

    @tag config: [max_pending: 1, flush_interval_ms: 60_000, drops_report_interval_ms: 10, hibernate_after: 50]
    test "logs a message it did not persist after hibernating", %{conn: conn, tenant_id: tenant_id} do
      {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
      pid = producer(conn)
      assert_eventually hibernating?(pid), interval: 10

      log =
        capture_log(fn ->
          :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
          {:error, :persistence_buffer_full} = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})

          assert_eventually :sys.get_state(pid).state.drops == %{}, interval: 10
        end)

      assert log =~ "PersistenceLimitReached: 1 message was broadcast but not persisted: persistence_buffer_full"
    end

    @tag config: [flush_interval_ms: 60_000]
    test "writes pending messages when it is shut down", %{conn: conn, tenant_id: tenant_id} do
      for i <- 1..10, do: :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{"i" => i}})
      :ok = GenServer.stop(producer(conn), :shutdown)

      assert count_messages(conn) == 10
    end

    test "stops when the database connection stops", %{conn: conn, tenant_id: tenant_id} do
      {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
      consumer = consumer(conn)
      ref = Process.monitor(consumer)

      GenServer.stop(conn)

      assert_receive {:DOWN, ^ref, :process, ^consumer, _reason}
    end

    test "stops when the consumer stops", %{conn: conn, tenant_id: tenant_id} do
      {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
      pid = producer(conn)
      ref = Process.monitor(pid)

      Process.exit(consumer(conn), :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    @tag config: [flush_interval_ms: 60_000]
    test "fails the queued messages when the consumer stops", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      for _ <- 1..3, do: :ok = Messages.persist(conn, tenant_id, "t", "e", {:json, %{}})
      pid = producer(conn)
      ref = Process.monitor(pid)

      log =
        capture_log([format: "$metadata$message\n", metadata: [:project]], fn ->
          Process.exit(consumer(conn), :kill)
          assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
        end)

      assert log =~
               "project=#{tenant_id} UnableToPersistMessage: 3 messages were broadcast but not persisted: persistence_unavailable"

      assert count_messages(conn) == 1
    end

    test "starts again on the next message after the consumer stops", %{conn: conn, tenant_id: tenant_id} do
      {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
      pid = producer(conn)
      ref = Process.monitor(pid)
      Process.exit(consumer(conn), :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
    end
  end

  describe "enqueue/6" do
    @tag config: [max_pending: 1, flush_interval_ms: 60_000]
    test "sends a rejected message's error to reply_to", %{conn: conn, tenant_id: tenant_id} do
      start_flush_interval(conn, tenant_id)
      first = make_ref()
      second = make_ref()

      :ok = Messages.enqueue(conn, tenant_id, "t", "e", {:json, %{}}, reply_to: {self(), first})
      :ok = Messages.enqueue(conn, tenant_id, "t", "e", {:json, %{}}, reply_to: {self(), second})

      assert_receive {^second, {:error, :persistence_buffer_full}}

      assert_receive {:telemetry, [:realtime, :tenants, :persist, :dropped], %{count: 1},
                      %{reason: :persistence_buffer_full}}

      refute_receive {^first, _}
    end
  end

  # Consumes the failed flush, so a test can wait for the next one
  defp fail_write(conn, tenant_id) do
    Postgrex.query!(conn, "DROP TABLE realtime.messages_#{partition_suffix()}", [])
    assert {:error, :persistence_failed} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
    assert_receive {:telemetry, [:realtime, :tenants, :persist, :flush], %{inserted: 0}, _}
    create_messages_partitions(conn, Date.utc_today(), Date.utc_today())
  end

  # Also waits for the consumer to send demand again, so the written message no longer counts as being written
  defp start_flush_interval(conn, tenant_id) do
    {:ok, _} = persist_and_wait(conn, tenant_id, "t", "e", {:json, %{}})
    assert_receive {:telemetry, [:realtime, :tenants, :persist, :flush], %{count: 1}, _}
    assert_eventually :sys.get_state(producer(conn)).state.writing == {0, 0}, interval: 10
  end

  defp persist_and_wait(conn, tenant_id, topic, event, payload, opts \\ []) do
    ref = make_ref()
    :ok = Messages.persist(conn, tenant_id, topic, event, payload, [reply_to: {self(), ref}] ++ opts)
    assert_receive {^ref, result}, 5_000
    result
  end

  defp producer(conn) do
    [{pid, _}] = Registry.lookup(Realtime.Registry.Unique, {Producer, conn})
    pid
  end

  defp consumer(conn), do: :sys.get_state(producer(conn)).state.consumer

  defp hibernating?(pid) do
    Process.info(pid, :current_function) in [
      {:current_function, {:erlang, :hibernate, 3}},
      {:current_function, {:gen_server, :loop_hibernate, 4}}
    ]
  end

  defp collect_flushes(expected, acc \\ [])
  defp collect_flushes(expected, acc) when expected <= 0, do: Enum.reverse(acc)

  defp collect_flushes(expected, acc) do
    assert_receive {:telemetry, [:realtime, :tenants, :persist, :flush], %{count: count} = measurements, _}, 5_000
    collect_flushes(expected - count, [measurements | acc])
  end

  defp collect_flushes_until_idle do
    receive do
      {:telemetry, [:realtime, :tenants, :persist, :flush], _, _} -> collect_flushes_until_idle()
    after
      200 -> :ok
    end
  end

  defp partition_suffix, do: Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "_")

  defp count_messages(conn) do
    %{rows: [[count]]} = Postgrex.query!(conn, "SELECT count(*) FROM realtime.messages", [])
    count
  end
end
