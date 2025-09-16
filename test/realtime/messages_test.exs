defmodule Realtime.MessagesTest do
  use Realtime.DataCase, async: true

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Repo

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

    date_start = Date.utc_today() |> Date.add(-10)
    date_end = Date.utc_today()
    create_messages_partitions(conn, date_start, date_end)
    %{conn: conn, tenant: tenant, date_start: date_start, date_end: date_end}
  end

  describe "replay/5" do
    test "invalid replay params" do
      assert Messages.replay(self(), "a topic", "not a number", 123) ==
               {:error, :invalid_replay_params}

      assert Messages.replay(self(), "a topic", 123, "not a number") ==
               {:error, :invalid_replay_params}

      assert Messages.replay(self(), "a topic", 253_402_300_800_000, 10) ==
               {:error, :invalid_replay_params}
    end

    test "empty replay", %{conn: conn} do
      assert Messages.replay(conn, "test", 0, 10) == {:ok, [], MapSet.new()}
    end

    test "replay respects limit", %{conn: conn, tenant: tenant} do
      m1 =
        message_fixture(tenant, %{
          "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-1, :minute),
          "event" => "new",
          "extension" => "broadcast",
          "topic" => "test",
          "private" => true,
          "payload" => %{"value" => "new"}
        })

      message_fixture(tenant, %{
        "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-2, :minute),
        "event" => "old",
        "extension" => "broadcast",
        "topic" => "test",
        "private" => true,
        "payload" => %{"value" => "old"}
      })

      assert Messages.replay(conn, "test", 0, 1) == {:ok, [m1], MapSet.new([m1.id])}
    end

    test "replay private topic only", %{conn: conn, tenant: tenant} do
      privatem =
        message_fixture(tenant, %{
          "private" => true,
          "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-1, :minute),
          "event" => "new",
          "extension" => "broadcast",
          "topic" => "test",
          "payload" => %{"value" => "new"}
        })

      message_fixture(tenant, %{
        "private" => false,
        "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-2, :minute),
        "event" => "old",
        "extension" => "broadcast",
        "topic" => "test",
        "payload" => %{"value" => "old"}
      })

      assert Messages.replay(conn, "test", 0, 10) == {:ok, [privatem], MapSet.new([privatem.id])}
    end

    test "replay extension=broadcast", %{conn: conn, tenant: tenant} do
      privatem =
        message_fixture(tenant, %{
          "private" => true,
          "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-1, :minute),
          "event" => "new",
          "extension" => "broadcast",
          "topic" => "test",
          "payload" => %{"value" => "new"}
        })

      message_fixture(tenant, %{
        "private" => true,
        "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-2, :minute),
        "event" => "old",
        "extension" => "presence",
        "topic" => "test",
        "payload" => %{"value" => "old"}
      })

      assert Messages.replay(conn, "test", 0, 10) == {:ok, [privatem], MapSet.new([privatem.id])}
    end

    test "replay respects since", %{conn: conn, tenant: tenant} do
      m1 =
        message_fixture(tenant, %{
          "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-2, :minute),
          "event" => "first",
          "extension" => "broadcast",
          "topic" => "test",
          "private" => true,
          "payload" => %{"value" => "first"}
        })

      m2 =
        message_fixture(tenant, %{
          "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-1, :minute),
          "event" => "second",
          "extension" => "broadcast",
          "topic" => "test",
          "private" => true,
          "payload" => %{"value" => "second"}
        })

      message_fixture(tenant, %{
        "inserted_at" => NaiveDateTime.utc_now() |> NaiveDateTime.add(-10, :minute),
        "event" => "old",
        "extension" => "broadcast",
        "topic" => "test",
        "private" => true,
        "payload" => %{"value" => "old"}
      })

      since = DateTime.utc_now() |> DateTime.add(-3, :minute) |> DateTime.to_unix(:millisecond)

      assert Messages.replay(conn, "test", since, 10) == {:ok, [m1, m2], MapSet.new([m1.id, m2.id])}
    end

    test "replay respects hard max limit of 25", %{conn: conn, tenant: tenant} do
      for _i <- 1..30 do
        message_fixture(tenant, %{
          "inserted_at" => NaiveDateTime.utc_now(),
          "event" => "event",
          "extension" => "broadcast",
          "topic" => "test",
          "private" => true,
          "payload" => %{"value" => "message"}
        })
      end

      assert {:ok, messages, set} = Messages.replay(conn, "test", 0, 30)
      assert length(messages) == 25
      assert MapSet.size(set) == 25
    end

    test "replay respects hard min limit of 1", %{conn: conn, tenant: tenant} do
      message_fixture(tenant, %{
        "inserted_at" => NaiveDateTime.utc_now(),
        "event" => "event",
        "extension" => "broadcast",
        "topic" => "test",
        "private" => true,
        "payload" => %{"value" => "message"}
      })

      assert {:ok, messages, set} = Messages.replay(conn, "test", 0, 0)
      assert length(messages) == 1
      assert MapSet.size(set) == 1
    end

    test "distributed replay", %{conn: conn, tenant: tenant} do
      m =
        message_fixture(tenant, %{
          "inserted_at" => NaiveDateTime.utc_now(),
          "event" => "event",
          "extension" => "broadcast",
          "topic" => "test",
          "private" => true,
          "payload" => %{"value" => "message"}
        })

      {:ok, node} = Clustered.start()

      # Call remote node passing the database connection that is local to this node
      assert :erpc.call(node, Messages, :replay, [conn, "test", 0, 30]) == {:ok, [m], MapSet.new([m.id])}
    end

    test "distributed replay error", %{tenant: tenant} do
      message_fixture(tenant, %{
        "inserted_at" => NaiveDateTime.utc_now(),
        "event" => "event",
        "extension" => "broadcast",
        "topic" => "test",
        "private" => true,
        "payload" => %{"value" => "message"}
      })

      {:ok, node} = Clustered.start()

      # Call remote node passing the database connection that is local to this node
      pid = spawn(fn -> :ok end)
      assert :erpc.call(node, Messages, :replay, [pid, "test", 0, 30]) == {:error, :failed_to_replay_messages}
    end
  end

  describe "delete_old_messages/1" do
    test "delete_old_messages/1 deletes messages older than 72 hours", %{
      conn: conn,
      tenant: tenant,
      date_start: date_start,
      date_end: date_end
    } do
      utc_now = NaiveDateTime.utc_now()
      limit = NaiveDateTime.add(utc_now, -72, :hour)

      messages =
        for date <- Date.range(date_start, date_end) do
          inserted_at = date |> NaiveDateTime.new!(Time.new!(0, 0, 0))
          message_fixture(tenant, %{inserted_at: inserted_at})
        end

      assert length(messages) == 11

      to_keep =
        Enum.reject(
          messages,
          &(NaiveDateTime.compare(NaiveDateTime.beginning_of_day(limit), &1.inserted_at) == :gt)
        )

      assert :ok = Messages.delete_old_messages(conn)
      {:ok, current} = Repo.all(conn, from(m in Message), Message)

      assert Enum.sort(current) == Enum.sort(to_keep)
    end
  end
end
