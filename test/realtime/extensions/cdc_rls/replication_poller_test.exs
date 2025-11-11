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

  @change_json ~s({"table":"test","type":"INSERT","record":{"id": 34, "details": "test"},"columns":[{"name": "id", "type": "int4"}, {"name": "details", "type": "text"}],"errors":null,"schema":"public","commit_timestamp":"2025-10-13T07:50:28.066Z"})

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

      {:ok, tenant} =
        Realtime.Api.get_tenant_by_external_id(tenant.external_id)
        |> Realtime.Api.update_tenant(%{"max_events_per_second" => 123})

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

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)

      assert {:ok,
              %RateCounter{
                sum: sum,
                limit: %{
                  value: 123,
                  measurement: :avg,
                  triggered: false
                }
              }} = RateCounterHelper.tick!(rate)

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
                                                      {"INSERT", change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        assert Jason.decode!(change_json) == Jason.decode!(@change_json)
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

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounterHelper.tick!(rate)
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
                                                      {"INSERT", change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        assert Jason.decode!(change_json) == Jason.decode!(@change_json)
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

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounterHelper.tick!(rate)
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
                                                      {"INSERT", change_json, _sub_ids},
                                                      MessageDispatcher,
                                                      :postgres_changes ->
        assert Jason.decode!(change_json) == Jason.decode!(@change_json)
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

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounterHelper.tick!(rate)
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
        _node, ^tenant_id, ^topic, {"INSERT", change_json, _sub_ids}, MessageDispatcher, :postgres_changes ->
          assert Jason.decode!(change_json) == Jason.decode!(@change_json)
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

      node_subs = Enum.map(calls, fn [node, _, _, {"INSERT", _change_json, sub_ids}, _, _] -> {node, sub_ids} end)

      assert {node(), MapSet.new([sub1, sub3])} in node_subs
      assert {:"someothernode@127.0.0.1", MapSet.new([sub2])} in node_subs

      rate = Realtime.Tenants.db_events_per_second_rate(tenant)
      assert {:ok, %RateCounter{sum: sum}} = RateCounterHelper.tick!(rate)
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
  @subscription_ids MapSet.new(["417e76fd-9bc5-4b3e-bd5d-a031389c4a6b"])

  @old_record %{"id" => 12}
  @record %{"details" => "test", "id" => 12, "user_id" => 1}

  describe "generate_record/1" do
    test "INSERT" do
      wal_record = [
        {"type", "INSERT"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", nil},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      assert %NewRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "INSERT",
               subscription_ids: @subscription_ids,
               record: record,
               errors: nil
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "UPDATE" do
      wal_record = [
        {"type", "UPDATE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      assert %UpdatedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "UPDATE",
               subscription_ids: @subscription_ids,
               record: record,
               old_record: old_record,
               errors: nil
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "DELETE" do
      wal_record = [
        {"type", "DELETE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", nil},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", []}
      ]

      assert %DeletedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "DELETE",
               subscription_ids: @subscription_ids,
               old_record: old_record,
               errors: nil
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "INSERT, large payload error present" do
      wal_record = [
        {"type", "INSERT"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", nil},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      assert %NewRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "INSERT",
               subscription_ids: @subscription_ids,
               record: record,
               errors: ["Error 413: Payload Too Large"]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "INSERT, other errors present" do
      wal_record = [
        {"type", "INSERT"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", nil},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      assert %NewRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "INSERT",
               subscription_ids: @subscription_ids,
               record: record,
               errors: ["Error..."]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "UPDATE, large payload error present" do
      wal_record = [
        {"type", "UPDATE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      assert %UpdatedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "UPDATE",
               subscription_ids: @subscription_ids,
               record: record,
               old_record: old_record,
               errors: ["Error 413: Payload Too Large"]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "UPDATE, other errors present" do
      wal_record = [
        {"type", "UPDATE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", Jason.encode!(@record)},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      assert %UpdatedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "UPDATE",
               subscription_ids: @subscription_ids,
               record: record,
               old_record: old_record,
               errors: ["Error..."]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert record |> Jason.encode!() |> Jason.decode!() == @record
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "DELETE, large payload error present" do
      wal_record = [
        {"type", "DELETE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", nil},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error 413: Payload Too Large"]}
      ]

      assert %DeletedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "DELETE",
               subscription_ids: @subscription_ids,
               old_record: old_record,
               errors: ["Error 413: Payload Too Large"]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
    end

    test "DELETE, other errors present" do
      wal_record = [
        {"type", "DELETE"},
        {"schema", "public"},
        {"table", "todos"},
        {"columns", Jason.encode!(@columns)},
        {"record", nil},
        {"old_record", Jason.encode!(@old_record)},
        {"commit_timestamp", @ts},
        {"subscription_ids", [@subscription_id]},
        {"errors", ["Error..."]}
      ]

      assert %DeletedRecord{
               columns: columns,
               commit_timestamp: @ts,
               schema: "public",
               table: "todos",
               type: "DELETE",
               subscription_ids: @subscription_ids,
               old_record: old_record,
               errors: ["Error..."]
             } = generate_record(wal_record)

      # Encode then decode to get rid of the fragment
      assert old_record |> Jason.encode!() |> Jason.decode!() == @old_record
      assert columns |> Jason.encode!() |> Jason.decode!() == @columns
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
       columns: [
         "type",
         "schema",
         "table",
         "columns",
         "record",
         "old_record",
         "commit_timestamp",
         "subscription_ids",
         "errors"
       ],
       rows: [
         [
           "INSERT",
           "public",
           "test",
           "[{\"name\": \"id\", \"type\": \"int4\"}, {\"name\": \"details\", \"type\": \"text\"}]",
           "{\"id\": 34, \"details\": \"test\"}",
           nil,
           "2025-10-13T07:50:28.066Z",
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
