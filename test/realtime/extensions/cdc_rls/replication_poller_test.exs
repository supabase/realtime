defmodule Realtime.Extensions.PostgresCdcRls.ReplicationPollerTest do
  # Tweaking application env
  use Realtime.DataCase, async: false

  use Mimic

  alias Extensions.PostgresCdcRls.MessageDispatcher
  alias Extensions.PostgresCdcRls.ReplicationPoller, as: Poller
  alias Extensions.PostgresCdcRls.Replications

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  alias Realtime.RateCounter

  alias RealtimeWeb.TenantBroadcaster

  import Poller, only: [generate_record: 1]

  setup :set_mimic_global

  @change_json ~s({"table":"test","type":"INSERT","record":{"details":"test","id":55},"columns":[{"name":"id","type":"int4"},{"name":"details","type":"text"}],"errors":null,"schema":"public","commit_timestamp":"2025-10-13T07:50:28.066Z"})

  describe "poll" do
    setup do
      :telemetry.attach(
        __MODULE__,
        [:realtime, :replication, :poller, :query, :stop],
        &__MODULE__.handle_telemetry/4,
        pid: self()
      )

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      tenant = Containers.checkout_tenant(run_migrations: true)

      subscribers_pids_table = :ets.new(__MODULE__, [:public, :bag])
      subscribers_nodes_table = :ets.new(__MODULE__, [:public, :set])

      args =
        hd(tenant.extensions).settings
        |> Map.put("id", tenant.external_id)
        |> Map.put("subscribers_pids_table", subscribers_pids_table)
        |> Map.put("subscribers_nodes_table", subscribers_nodes_table)

      # unless specified it will return empty results
      empty_results = {:ok, %Postgrex.Result{rows: [], num_rows: 0}}
      stub(Replications, :list_changes, fn _, _, _, _, _ -> empty_results end)

      %{args: args, tenant: tenant}
    end

    test "handles no new changes", %{args: args, tenant: tenant} do
      tenant_id = args["id"]
      reject(&TenantBroadcaster.pubsub_direct_broadcast/6)
      reject(&TenantBroadcaster.pubsub_broadcast/5)
      start_link_supervised!({Poller, args})

      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      refute_receive _any

      # Wait for RateCounter to update
      Process.sleep(1100)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounter.get(rate)
      assert sum == 0
    end

    test "handles new changes with missing ets table", %{args: args, tenant: tenant} do
      tenant_id = args["id"]

      :ets.delete(args["subscribers_nodes_table"])

      results =
        build_result([
          <<71, 36, 83, 212, 168, 9, 17, 240, 165, 186, 118, 202, 193, 157, 232, 187>>,
          <<251, 188, 190, 118, 168, 119, 17, 240, 188, 87, 118, 202, 193, 157, 232, 187>>
        ])

      expect(Replications, :list_changes, fn _, _, _, _, _ -> results end)
      reject(&TenantBroadcaster.pubsub_direct_broadcast/6)

      # Broadcast to the whole cluster due to missing node information
      expect(TenantBroadcaster, :pubsub_broadcast, fn ^tenant_id,
                                                      "realtime:postgres:" <> ^tenant_id,
                                                      {"INSERT", @change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        :ok
      end)

      start_link_supervised!({Poller, args})

      # First poll with changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Second poll without changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Wait for RateCounter to update
      Process.sleep(1100)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounter.get(rate)
      assert sum == 2
    end

    test "handles new changes with no subscription nodes", %{args: args, tenant: tenant} do
      tenant_id = args["id"]

      results =
        build_result([
          <<71, 36, 83, 212, 168, 9, 17, 240, 165, 186, 118, 202, 193, 157, 232, 187>>,
          <<251, 188, 190, 118, 168, 119, 17, 240, 188, 87, 118, 202, 193, 157, 232, 187>>
        ])

      expect(Replications, :list_changes, fn _, _, _, _, _ -> results end)
      reject(&TenantBroadcaster.pubsub_direct_broadcast/6)

      # Broadcast to the whole cluster due to missing node information
      expect(TenantBroadcaster, :pubsub_broadcast, fn ^tenant_id,
                                                      "realtime:postgres:" <> ^tenant_id,
                                                      {"INSERT", @change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        :ok
      end)

      start_link_supervised!({Poller, args})

      # First poll with changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Second poll without changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Wait for RateCounter to update
      Process.sleep(1100)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounter.get(rate)
      assert sum == 2
    end

    test "handles new changes with missing subscription nodes", %{args: args, tenant: tenant} do
      tenant_id = args["id"]

      results =
        build_result([
          sub1 = <<71, 36, 83, 212, 168, 9, 17, 240, 165, 186, 118, 202, 193, 157, 232, 187>>,
          <<251, 188, 190, 118, 168, 119, 17, 240, 188, 87, 118, 202, 193, 157, 232, 187>>
        ])

      # Only one subscription has node information
      :ets.insert(args["subscribers_nodes_table"], {sub1, node()})

      expect(Replications, :list_changes, fn _, _, _, _, _ -> results end)
      reject(&TenantBroadcaster.pubsub_direct_broadcast/6)

      # Broadcast to the whole cluster due to missing node information
      expect(TenantBroadcaster, :pubsub_broadcast, fn ^tenant_id,
                                                      "realtime:postgres:" <> ^tenant_id,
                                                      {"INSERT", @change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        :ok
      end)

      start_link_supervised!({Poller, args})

      # First poll with changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Second poll without changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Wait for RateCounter to update
      Process.sleep(1100)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounter.get(rate)
      assert sum == 2
    end

    test "handles new changes with subscription nodes information", %{args: args, tenant: tenant} do
      tenant_id = args["id"]

      results =
        build_result([
          sub1 = <<71, 36, 83, 212, 168, 9, 17, 240, 165, 186, 118, 202, 193, 157, 232, 187>>,
          sub2 = <<251, 188, 190, 118, 168, 119, 17, 240, 188, 87, 118, 202, 193, 157, 232, 187>>,
          sub3 = <<49, 59, 209, 112, 173, 77, 17, 240, 191, 41, 118, 202, 193, 157, 232, 187>>
        ])

      # All subscriptions have node information
      :ets.insert(args["subscribers_nodes_table"], {sub1, node()})
      :ets.insert(args["subscribers_nodes_table"], {sub2, :"someothernode@127.0.0.1"})
      :ets.insert(args["subscribers_nodes_table"], {sub3, node()})

      expect(Replications, :list_changes, fn _, _, _, _, _ -> results end)
      reject(&TenantBroadcaster.pubsub_broadcast/5)

      topic = "realtime:postgres:" <> tenant_id

      # # Broadcast to the exact nodes only
      expect(TenantBroadcaster, :pubsub_direct_broadcast, 2, fn
        _node, ^tenant_id, ^topic, {"INSERT", @change_json, _sub_ids}, MessageDispatcher, :postgres_changes ->
          :ok
      end)

      start_link_supervised!({Poller, args})

      # First poll with changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      # Second poll without changes
      assert_receive {
                       :telemetry,
                       [:realtime, :replication, :poller, :query, :stop],
                       %{duration: _},
                       %{tenant: ^tenant_id}
                     },
                     500

      calls = calls(TenantBroadcaster, :pubsub_direct_broadcast, 6)

      assert Enum.count(calls) == 2

      node_subs = Enum.map(calls, fn [node, _, _, {"INSERT", @change_json, sub_ids}, _, _] -> {node, sub_ids} end)

      assert {node(), MapSet.new([sub1, sub3])} in node_subs
      assert {:"someothernode@127.0.0.1", MapSet.new([sub2])} in node_subs

      # Wait for RateCounter to update
      Process.sleep(1100)

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounter.get(rate)
      assert sum == 3
    end
  end

  @columns [
    %{"name" => "id", "type" => "int8"},
    %{"name" => "details", "type" => "text"},
    %{"name" => "user_id", "type" => "int8"}
  ]

  @ts "2021-11-05T17:20:51.52406+00:00"

  @subscription_id "417e76fd-9bc5-4b3e-bd5d-a031389c4a6b"

  describe "generate_record/1" do
    test "INSERT" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "record" => %{"details" => "test", "id" => 12, "user_id" => 1},
           "schema" => "public",
           "table" => "todos",
           "type" => "INSERT"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      expected = %NewRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "INSERT",
        subscription_ids: MapSet.new([@subscription_id]),
        record: %{"details" => "test", "id" => 12, "user_id" => 1},
        errors: nil
      }

      assert expected == generate_record(record)
    end

    test "UPDATE" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "old_record" => %{"id" => 12},
           "record" => %{"details" => "test1", "id" => 12, "user_id" => 1},
           "schema" => "public",
           "table" => "todos",
           "type" => "UPDATE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      expected = %UpdatedRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "UPDATE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{"id" => 12},
        record: %{"details" => "test1", "id" => 12, "user_id" => 1},
        errors: nil
      }

      assert expected == generate_record(record)
    end

    test "DELETE" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "old_record" => %{"id" => 15},
           "schema" => "public",
           "table" => "todos",
           "type" => "DELETE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      expected = %DeletedRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "DELETE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{"id" => 15},
        errors: nil
      }

      assert expected == generate_record(record)
    end

    test "INSERT, large payload error present" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "record" => %{"details" => "test", "id" => 12, "user_id" => 1},
           "schema" => "public",
           "table" => "todos",
           "type" => "INSERT"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      expected = %NewRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "INSERT",
        subscription_ids: MapSet.new([@subscription_id]),
        record: %{"details" => "test", "id" => 12, "user_id" => 1},
        errors: ["Error 413: Payload Too Large"]
      }

      assert expected == generate_record(record)
    end

    test "INSERT, other errors present" do
      record = [
        {"wal",
         %{
           "schema" => "public",
           "table" => "todos",
           "type" => "INSERT"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      expected = %NewRecord{
        columns: [],
        commit_timestamp: nil,
        schema: "public",
        table: "todos",
        type: "INSERT",
        subscription_ids: MapSet.new([@subscription_id]),
        record: %{},
        errors: ["Error..."]
      }

      assert expected == generate_record(record)
    end

    test "UPDATE, large payload error present" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "old_record" => %{"details" => "prev test", "id" => 12, "user_id" => 1},
           "record" => %{"details" => "test", "id" => 12, "user_id" => 1},
           "schema" => "public",
           "table" => "todos",
           "type" => "UPDATE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      expected = %UpdatedRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "UPDATE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{"details" => "prev test", "id" => 12, "user_id" => 1},
        record: %{"details" => "test", "id" => 12, "user_id" => 1},
        errors: ["Error 413: Payload Too Large"]
      }

      assert expected == generate_record(record)
    end

    test "UPDATE, other errors present" do
      record = [
        {"wal",
         %{
           "schema" => "public",
           "table" => "todos",
           "type" => "UPDATE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      expected = %UpdatedRecord{
        columns: [],
        commit_timestamp: nil,
        schema: "public",
        table: "todos",
        type: "UPDATE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{},
        record: %{},
        errors: ["Error..."]
      }

      assert expected == generate_record(record)
    end

    test "DELETE, large payload error present" do
      record = [
        {"wal",
         %{
           "columns" => @columns,
           "commit_timestamp" => @ts,
           "old_record" => %{"details" => "test", "id" => 12, "user_id" => 1},
           "schema" => "public",
           "table" => "todos",
           "type" => "DELETE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      expected = %DeletedRecord{
        columns: @columns,
        commit_timestamp: @ts,
        schema: "public",
        table: "todos",
        type: "DELETE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{"details" => "test", "id" => 12, "user_id" => 1},
        errors: ["Error 413: Payload Too Large"]
      }

      assert expected == generate_record(record)
    end

    test "DELETE, other errors present" do
      record = [
        {"wal",
         %{
           "schema" => "public",
           "table" => "todos",
           "type" => "DELETE"
         }},
        {"is_rls_enabled", false},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      expected = %DeletedRecord{
        columns: [],
        commit_timestamp: nil,
        schema: "public",
        table: "todos",
        type: "DELETE",
        subscription_ids: MapSet.new([@subscription_id]),
        old_record: %{},
        errors: ["Error..."]
      }

      assert expected == generate_record(record)
    end
  end

  describe "slot_name_suffix/0" do
    setup do
      slot_name_suffix = Application.get_env(:realtime, :slot_name_suffix)

      on_exit(fn -> Application.put_env(:realtime, :slot_name_suffix, slot_name_suffix) end)
    end

    test "uses Application.get_env/2 with key :slot_name_suffix" do
      slot_name_suffix = Generators.random_string()
      Application.put_env(:realtime, :slot_name_suffix, slot_name_suffix)
      assert Poller.slot_name_suffix() == "_" <> slot_name_suffix
    end

    test "defaults to no suffix" do
      assert Poller.slot_name_suffix() == ""
    end
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {:telemetry, event, measures, metadata})

  defp build_result(subscription_ids) do
    {:ok,
     %Postgrex.Result{
       command: :select,
       columns: ["wal", "is_rls_enabled", "subscription_ids", "errors"],
       rows: [
         [
           %{
             "columns" => [
               %{"name" => "id", "type" => "int4"},
               %{"name" => "details", "type" => "text"}
             ],
             "commit_timestamp" => "2025-10-13T07:50:28.066Z",
             "record" => %{"details" => "test", "id" => 55},
             "schema" => "public",
             "table" => "test",
             "type" => "INSERT"
           },
           false,
           subscription_ids,
           []
         ]
       ],
       num_rows: 1,
       connection_id: 123,
       messages: []
     }}
  end
end
