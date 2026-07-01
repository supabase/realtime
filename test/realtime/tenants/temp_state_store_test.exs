defmodule Realtime.Tenants.TempStateStoreTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.TempStateStore

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    channel_name = "room:" <> random_string()
    {:ok, store} = TempStateStore.start(tenant, self(), channel_name, db_conn)
    %{tenant: tenant, store: store, channel_name: channel_name, db_conn: db_conn}
  end

  describe "put/3" do
    test "inserts a new key and returns version 1", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
    end

    test "upserts an existing key and bumps the version", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, 2} = TempStateStore.put(store, "k", %{"a" => 2})
      assert {:ok, %{value: %{"a" => 2}, version: 2}} = TempStateStore.get(store, "k")
    end
  end

  describe "insert/3" do
    test "inserts a key that does not exist", %{store: store} do
      assert {:ok, 1} = TempStateStore.insert(store, "k", %{"a" => 1})
    end

    test "returns :already_exists when the key is present", %{store: store} do
      assert {:ok, 1} = TempStateStore.insert(store, "k", %{"a" => 1})
      assert {:error, :already_exists} = TempStateStore.insert(store, "k", %{"a" => 2})
    end
  end

  describe "update/3" do
    test "updates an existing key and bumps the version", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, 2} = TempStateStore.update(store, "k", %{"a" => 2})
    end

    test "returns :not_found when the key is missing", %{store: store} do
      assert {:error, :not_found} = TempStateStore.update(store, "missing", %{"a" => 1})
    end

    test "compare-and-set applies when the expected version matches", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, 2} = TempStateStore.update(store, "k", %{"a" => 2}, 1)
    end

    test "compare-and-set returns the current version on mismatch", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, 2} = TempStateStore.update(store, "k", %{"a" => 2})
      assert {:error, {:version_mismatch, 2}} = TempStateStore.update(store, "k", %{"a" => 3}, 1)
    end

    test "compare-and-set on a missing key returns :not_found", %{store: store} do
      assert {:error, :not_found} = TempStateStore.update(store, "missing", %{"a" => 1}, 1)
    end
  end

  describe "delete/3 compare-and-set" do
    test "deletes when the expected version matches", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, :deleted} = TempStateStore.delete(store, "k", 1)
    end

    test "returns the current version on mismatch", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, 2} = TempStateStore.update(store, "k", %{"a" => 2})
      assert {:error, {:version_mismatch, 2}} = TempStateStore.delete(store, "k", 1)
    end

    test "returns :not_found when the key is missing", %{store: store} do
      assert {:error, :not_found} = TempStateStore.delete(store, "missing", 1)
    end
  end

  describe "get/2" do
    test "returns the stored value, version and updated_at", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"nested" => [1, 2, 3]})
      assert {:ok, result} = TempStateStore.get(store, "k")
      assert %{value: %{"nested" => [1, 2, 3]}, version: 1, updated_at: %DateTime{}} = result
    end

    test "returns :not_found when the key is missing", %{store: store} do
      assert {:error, :not_found} = TempStateStore.get(store, "missing")
    end
  end

  describe "delete/2" do
    test "deletes an existing key", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "k", %{"a" => 1})
      assert {:ok, :deleted} = TempStateStore.delete(store, "k")
      assert {:error, :not_found} = TempStateStore.get(store, "k")
    end

    test "returns :not_found when the key is missing", %{store: store} do
      assert {:error, :not_found} = TempStateStore.delete(store, "missing")
    end
  end

  describe "count/1" do
    test "returns 0 on an empty store and the row count after inserts", %{store: store} do
      assert {:ok, 0} = TempStateStore.count(store)
      assert {:ok, 1} = TempStateStore.put(store, "a", %{})
      assert {:ok, 1} = TempStateStore.put(store, "b", %{})
      assert {:ok, 2} = TempStateStore.count(store)
    end
  end

  describe "clear/1" do
    test "removes all rows", %{store: store} do
      assert {:ok, 1} = TempStateStore.put(store, "a", %{})
      assert {:ok, 1} = TempStateStore.put(store, "b", %{})
      assert {:ok, 2} = TempStateStore.count(store)
      assert :ok = TempStateStore.clear(store)
      assert {:ok, 0} = TempStateStore.count(store)
    end
  end

  describe "lifecycle" do
    test "the store stops when the monitored process goes down", %{tenant: tenant, db_conn: db_conn} do
      monitored = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, store} = TempStateStore.start(tenant, monitored, "room:" <> random_string(), db_conn)
      ref = Process.monitor(store)

      Process.exit(monitored, :kill)

      assert_receive {:DOWN, ^ref, :process, ^store, _reason}, 2000
    end

    test "calls to a stopped store return {:error, :unavailable}", %{store: store} do
      ref = Process.monitor(store)
      GenServer.stop(store)
      assert_receive {:DOWN, ^ref, :process, ^store, _reason}, 2000

      assert {:error, :unavailable} = TempStateStore.put(store, "k", %{})
    end

    test "two channels get isolated state", %{tenant: tenant, db_conn: db_conn} do
      {:ok, store_a} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)
      {:ok, store_b} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)

      assert {:ok, 1} = TempStateStore.put(store_a, "k", %{"who" => "a"})
      assert {:error, :not_found} = TempStateStore.get(store_b, "k")
    end
  end

  describe "table_name/1" do
    test "is deterministic, a valid identifier and within Postgres' 63 byte limit" do
      name = TempStateStore.table_name("room:Lobby #1")

      assert name == TempStateStore.table_name("room:Lobby #1")
      assert String.starts_with?(name, "realtime_state_")
      assert byte_size(name) <= 63
      assert name =~ ~r/\A[a-z0-9_]+\z/
    end

    test "different channels produce different table names" do
      refute TempStateStore.table_name("room:a") == TempStateStore.table_name("room:b")
    end
  end
end
