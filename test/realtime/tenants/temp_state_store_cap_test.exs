defmodule Realtime.Tenants.TempStateStoreCapTest do
  use Realtime.DataCase, async: false

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.TempStateStore

  setup do
    prev = Application.get_env(:realtime, :temp_state_store_max_per_tenant)
    Application.put_env(:realtime, :temp_state_store_max_per_tenant, 2)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:realtime, :temp_state_store_max_per_tenant)
        value -> Application.put_env(:realtime, :temp_state_store_max_per_tenant, value)
      end
    end)

    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    %{tenant: tenant, db_conn: db_conn}
  end

  test "rejects new stores once the limit is reached", %{tenant: tenant, db_conn: db_conn} do
    assert {:ok, _} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)
    assert {:ok, _} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)

    assert {:error, :too_many_state_stores} =
             TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)
  end

  describe "input limits" do
    setup %{tenant: tenant, db_conn: db_conn} do
      Application.put_env(:realtime, :temp_state_store_max_value_bytes, 100)
      Application.put_env(:realtime, :temp_state_store_max_keys, 2)

      on_exit(fn ->
        Application.delete_env(:realtime, :temp_state_store_max_value_bytes)
        Application.delete_env(:realtime, :temp_state_store_max_keys)
      end)

      {:ok, store} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)
      %{store: store}
    end

    test "rejects values over the configured byte limit", %{store: store} do
      assert {:error, :value_too_large} = TempStateStore.put(store, "k", %{"blob" => String.duplicate("x", 200)})
      assert {:ok, _} = TempStateStore.put(store, "k", %{"small" => 1})
    end

    test "rejects keys over the byte limit", %{store: store} do
      assert {:error, :key_too_large} = TempStateStore.put(store, String.duplicate("k", 2000), %{})
    end

    test "rejects new keys past max_keys but still allows updating existing keys", %{store: store} do
      assert {:ok, _} = TempStateStore.put(store, "a", %{})
      assert {:ok, _} = TempStateStore.put(store, "b", %{})
      assert {:error, :limit_reached} = TempStateStore.put(store, "c", %{})
      assert {:error, :limit_reached} = TempStateStore.insert(store, "c", %{})

      assert {:ok, 2} = TempStateStore.put(store, "a", %{"updated" => true})
    end
  end

  test "a store that stops frees a slot", %{tenant: tenant, db_conn: db_conn} do
    {:ok, store} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)
    {:ok, _} = TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)

    assert {:error, :too_many_state_stores} =
             TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn)

    ref = Process.monitor(store)
    GenServer.stop(store)
    assert_receive {:DOWN, ^ref, :process, ^store, _reason}, 2000

    assert eventually(fn ->
             match?({:ok, _}, TempStateStore.start(tenant, self(), "room:" <> random_string(), db_conn))
           end)
  end
end
