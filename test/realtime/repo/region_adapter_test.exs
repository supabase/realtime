defmodule Realtime.Repo.RegionAdapterTest do
  use ExUnit.Case, async: true
  use Mimic
  doctest Realtime.Repo.RegionAdapter
  alias Realtime.Repo.RegionAdapter
  alias Realtime.Nodes
  alias Realtime.GenRpc

  setup :set_mimic_global
  setup :verify_on_exit!

  describe "init/1" do
    test "initializes the adapter with current node when in master region" do
      previous_region = Application.get_env(:realtime, :region)
      previous_master_region = Application.get_env(:realtime, :master_region)

      on_exit(fn ->
        Application.put_env(:realtime, :region, previous_region)
        Application.put_env(:realtime, :master_region, previous_master_region)
      end)

      Application.put_env(:realtime, :region, "us-east-1")
      Application.put_env(:realtime, :master_region, "us-east-1")
      {:ok, _child_spec, adapter_meta} = RegionAdapter.init(Application.get_env(:realtime, Realtime.Repo))

      assert adapter_meta[:remote] == node()
    end

    test "initializes the adapter with remote node when in non-master region" do
      previous_region = Application.get_env(:realtime, :region)
      previous_master_region = Application.get_env(:realtime, :master_region)

      on_exit(fn ->
        Application.put_env(:realtime, :region, previous_region)
        Application.put_env(:realtime, :master_region, previous_master_region)
      end)

      master_region = "ap-southeast-2"
      remote_node = :"remote_master_node@127.0.0.1"

      expect(Nodes, :node_from_region, fn ^master_region, _current_node ->
        {:ok, remote_node}
      end)

      Application.put_env(:realtime, :region, "us-east-1")
      Application.put_env(:realtime, :master_region, master_region)

      {:ok, _child_spec, adapter_meta} = RegionAdapter.init(Application.get_env(:realtime, Realtime.Repo))

      assert adapter_meta[:remote] == remote_node
    end

    test "initializes the adapter with current node when master region has no nodes" do
      previous_region = Application.get_env(:realtime, :region)
      previous_master_region = Application.get_env(:realtime, :master_region)

      on_exit(fn ->
        Application.put_env(:realtime, :region, previous_region)
        Application.put_env(:realtime, :master_region, previous_master_region)
      end)

      Application.put_env(:realtime, :region, "us-east-1")
      Application.put_env(:realtime, :master_region, "non-existent-region")

      {:ok, _child_spec, adapter_meta} = RegionAdapter.init(Application.get_env(:realtime, Realtime.Repo))

      assert adapter_meta[:remote] == node()
    end
  end

  describe "local operations (in master region)" do
    setup do
      previous_region = Application.get_env(:realtime, :region)
      previous_master_region = Application.get_env(:realtime, :master_region)

      on_exit(fn ->
        Application.put_env(:realtime, :region, previous_region)
        Application.put_env(:realtime, :master_region, previous_master_region)
      end)

      Application.put_env(:realtime, :region, "us-east-1")
      Application.put_env(:realtime, :master_region, "us-east-1")

      adapter_meta = %{remote: nil, pid: self()}
      %{adapter_meta: adapter_meta}
    end

    test "execute calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      query_meta = %{}
      query = %Ecto.Query{}
      params = []
      opts = []
      expected_result = {:ok, %{num_rows: 1, rows: [[1]]}}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :execute, fn ^adapter_meta, ^query_meta, ^query, ^params, ^opts ->
        expected_result
      end)

      result = RegionAdapter.execute(adapter_meta, query_meta, query, params, opts)
      assert result == expected_result
    end

    test "insert calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      schema_meta = %{}
      params = %{name: "test"}
      on_conflict = :nothing
      returning = [:id]
      opts = []
      expected_result = {:ok, [id: 1]}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :insert, fn ^adapter_meta,
                                                 ^schema_meta,
                                                 ^params,
                                                 ^on_conflict,
                                                 ^returning,
                                                 ^opts ->
        expected_result
      end)

      result = RegionAdapter.insert(adapter_meta, schema_meta, params, on_conflict, returning, opts)
      assert result == expected_result
    end

    test "update calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      schema_meta = %{}
      fields = [:name]
      params = %{name: "updated"}
      returning = [:id]
      opts = []
      expected_result = {:ok, [id: 1]}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :update, fn ^adapter_meta, ^schema_meta, ^fields, ^params, ^returning, ^opts ->
        expected_result
      end)

      result = RegionAdapter.update(adapter_meta, schema_meta, fields, params, returning, opts)
      assert result == expected_result
    end

    test "delete calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      schema_meta = %{}
      params = %{id: 1}
      returning = [:id]
      opts = []
      expected_result = {:ok, [id: 1]}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :delete, fn ^adapter_meta, ^schema_meta, ^params, ^returning, ^opts ->
        expected_result
      end)

      result = RegionAdapter.delete(adapter_meta, schema_meta, params, returning, opts)
      assert result == expected_result
    end

    test "transaction calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      opts = []
      fun = fn -> :ok end
      expected_result = {:ok, :ok}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :transaction, fn ^adapter_meta, ^opts, ^fun ->
        expected_result
      end)

      result = RegionAdapter.transaction(adapter_meta, opts, fun)
      assert result == expected_result
    end

    test "checked_out? calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      expected_result = false

      expect(Ecto.Adapters.Postgres, :checked_out?, fn ^adapter_meta ->
        expected_result
      end)

      result = RegionAdapter.checked_out?(adapter_meta)
      assert result == expected_result
    end

    test "insert_all calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      schema_meta = %{}
      header = [:name]
      rows = [[{:name, "test1"}], [{:name, "test2"}]]
      on_conflict = :nothing
      returning = [:id]
      placeholders = []
      opts = []
      expected_result = {2, nil}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :insert_all, fn ^adapter_meta,
                                                     ^schema_meta,
                                                     ^header,
                                                     ^rows,
                                                     ^on_conflict,
                                                     ^returning,
                                                     ^placeholders,
                                                     ^opts ->
        expected_result
      end)

      result =
        RegionAdapter.insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts)

      assert result == expected_result
    end

    test "stream calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      query_meta = %{}
      query = %Ecto.Query{}
      params = []
      opts = []
      expected_stream = %DBConnection.Stream{}

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :stream, fn ^adapter_meta, ^query_meta, ^query, ^params, ^opts ->
        expected_stream
      end)

      result = RegionAdapter.stream(adapter_meta, query_meta, query, params, opts)
      assert result == expected_stream
    end

    test "in_transaction? calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      expected_result = false

      reject(GenRpc, :call, 5)

      expect(Ecto.Adapters.Postgres, :in_transaction?, fn ^adapter_meta ->
        expected_result
      end)

      result = RegionAdapter.in_transaction?(adapter_meta)
      assert result == expected_result
    end

    test "checkout calls Postgres adapter directly when in master region", %{adapter_meta: adapter_meta} do
      config = []
      function = fn -> :ok end
      expected_result = :ok

      expect(Ecto.Adapters.Postgres, :checkout, fn ^adapter_meta, ^config, ^function ->
        expected_result
      end)

      result = RegionAdapter.checkout(adapter_meta, config, function)
      assert result == expected_result
    end
  end

  describe "remote operations (in non-master region)" do
    setup do
      previous_region = Application.get_env(:realtime, :region)
      previous_master_region = Application.get_env(:realtime, :master_region)

      on_exit(fn ->
        Application.put_env(:realtime, :region, previous_region)
        Application.put_env(:realtime, :master_region, previous_master_region)
      end)

      master_region = "ap-southeast-2"
      remote_node = :"remote_master_node@127.0.0.1"

      Application.put_env(:realtime, :region, "us-east-1")
      Application.put_env(:realtime, :master_region, master_region)

      stub(Nodes, :node_from_region, fn ^master_region, _current_node ->
        {:ok, remote_node}
      end)

      adapter_meta = %{remote: remote_node, pid: self()}
      %{adapter_meta: adapter_meta, remote_node: remote_node}
    end

    test "execute routes via GenRpc when in non-master region", %{adapter_meta: adapter_meta, remote_node: remote_node} do
      query_meta = %{}
      query = %Ecto.Query{}
      params = []
      opts = []
      expected_result = {:ok, %{num_rows: 1, rows: [[1]]}}

      expect(GenRpc, :call, fn ^remote_node,
                               Realtime.Repo.RegionAdapter,
                               :execute,
                               [^adapter_meta, ^query_meta, ^query, ^params, ^opts],
                               [] ->
        expected_result
      end)

      result = RegionAdapter.execute(adapter_meta, query_meta, query, params, opts)
      assert result == expected_result
    end

    test "insert routes via GenRpc when in non-master region", %{adapter_meta: adapter_meta, remote_node: remote_node} do
      schema_meta = %{}
      params = %{name: "test"}
      on_conflict = :nothing
      returning = [:id]
      opts = []
      expected_result = {:ok, %{id: 1, name: "test"}}

      expect(GenRpc, :call, fn ^remote_node,
                               Realtime.Repo.RegionAdapter,
                               :insert,
                               [^adapter_meta, ^schema_meta, ^params, ^on_conflict, ^returning, ^opts],
                               [] ->
        expected_result
      end)

      result = RegionAdapter.insert(adapter_meta, schema_meta, params, on_conflict, returning, opts)
      assert result == expected_result
    end

    test "update routes via GenRpc when in non-master region", %{adapter_meta: adapter_meta, remote_node: remote_node} do
      schema_meta = %{}
      fields = [:name]
      params = %{name: "updated"}
      returning = [:id]
      opts = []
      expected_result = {:ok, %{id: 1, name: "updated"}}

      expect(GenRpc, :call, fn ^remote_node,
                               Realtime.Repo.RegionAdapter,
                               :update,
                               [^adapter_meta, ^schema_meta, ^fields, ^params, ^returning, ^opts],
                               [] ->
        expected_result
      end)

      result = RegionAdapter.update(adapter_meta, schema_meta, fields, params, returning, opts)
      assert result == expected_result
    end

    test "delete routes via GenRpc when in non-master region", %{adapter_meta: adapter_meta, remote_node: remote_node} do
      schema_meta = %{}
      params = %{id: 1}
      returning = [:id]
      opts = []
      expected_result = {:ok, %{id: 1}}

      expect(GenRpc, :call, fn ^remote_node,
                               Realtime.Repo.RegionAdapter,
                               :delete,
                               [^adapter_meta, ^schema_meta, ^params, ^returning, ^opts],
                               [] ->
        expected_result
      end)

      result = RegionAdapter.delete(adapter_meta, schema_meta, params, returning, opts)
      assert result == expected_result
    end

    test "insert_all routes via GenRpc when in non-master region", %{
      adapter_meta: adapter_meta,
      remote_node: remote_node
    } do
      schema_meta = %{}
      header = [:name]
      rows = [[:name], ["test"]]
      on_conflict = :nothing
      returning = [:id]
      placeholders = []
      opts = []
      expected_result = {:ok, 1}

      expect(GenRpc, :call, fn ^remote_node,
                               Realtime.Repo.RegionAdapter,
                               :insert_all,
                               [
                                 ^adapter_meta,
                                 ^schema_meta,
                                 ^header,
                                 ^rows,
                                 ^on_conflict,
                                 ^returning,
                                 ^placeholders,
                                 ^opts
                               ],
                               [] ->
        expected_result
      end)

      result =
        RegionAdapter.insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts)

      assert result == expected_result
    end

    test "stream raises error when in non-master region", %{adapter_meta: adapter_meta} do
      query_meta = %{}
      query = %Ecto.Query{}
      params = []
      opts = []

      assert_raise RuntimeError, "stream is not supported on remote nodes", fn ->
        RegionAdapter.stream(adapter_meta, query_meta, query, params, opts)
      end
    end

    test "transaction raises error when in non-master region", %{adapter_meta: adapter_meta} do
      opts = []
      fun = fn -> :ok end

      assert_raise RuntimeError, "transaction is not supported on remote nodes", fn ->
        RegionAdapter.transaction(adapter_meta, opts, fun)
      end
    end

    test "in_transaction? raises error when in non-master region", %{adapter_meta: adapter_meta} do
      assert_raise RuntimeError, "in_transaction? is not supported on remote nodes", fn ->
        RegionAdapter.in_transaction?(adapter_meta)
      end
    end

    test "rollback raises error when in non-master region", %{adapter_meta: adapter_meta} do
      value = :some_value

      assert_raise RuntimeError, "rollback is not supported on remote nodes", fn ->
        RegionAdapter.rollback(adapter_meta, value)
      end
    end

    test "checked_out? raises error when in non-master region", %{adapter_meta: adapter_meta} do
      assert_raise RuntimeError, "checked_out? is not supported on remote nodes", fn ->
        RegionAdapter.checked_out?(adapter_meta)
      end
    end

    test "checkout raises error when in non-master region", %{adapter_meta: adapter_meta} do
      config = []
      function = fn -> :ok end

      assert_raise RuntimeError, "checkout is not supported on remote nodes", fn ->
        RegionAdapter.checkout(adapter_meta, config, function)
      end
    end

    test "storage_up raises error when in non-master region" do
      opts = []

      assert_raise RuntimeError, "storage_up is not supported on remote nodes", fn ->
        RegionAdapter.storage_up(opts)
      end
    end

    test "storage_down raises error when in non-master region" do
      opts = []

      assert_raise RuntimeError, "storage_down is not supported on remote nodes", fn ->
        RegionAdapter.storage_down(opts)
      end
    end

    test "storage_status raises error when in non-master region" do
      opts = []

      assert_raise RuntimeError, "storage_status is not supported on remote nodes", fn ->
        RegionAdapter.storage_status(opts)
      end
    end

    test "execute_ddl raises error when in non-master region", %{adapter_meta: adapter_meta} do
      definition = {:create, :table, []}
      opts = []

      assert_raise RuntimeError, "execute_ddl is not supported on remote nodes", fn ->
        RegionAdapter.execute_ddl(adapter_meta, definition, opts)
      end
    end

    test "supports_ddl_transaction? raises error when in non-master region" do
      assert_raise RuntimeError, "supports_ddl_transaction? is not supported on remote nodes", fn ->
        RegionAdapter.supports_ddl_transaction?()
      end
    end

    test "lock_for_migrations raises error when in non-master region", %{adapter_meta: adapter_meta} do
      opts = []
      fun = fn -> :ok end

      assert_raise RuntimeError, "lock_for_migrations is not supported on remote nodes", fn ->
        RegionAdapter.lock_for_migrations(adapter_meta, opts, fun)
      end
    end
  end
end
