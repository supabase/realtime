defmodule Realtime.ReplicationPollerTest do
  use ExUnit.Case

  import Realtime.RLS.ReplicationPoller, only: [generate_record: 1]

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  @columns [
    %{"name" => "id", "type" => "int8"},
    %{"name" => "details", "type" => "text"},
    %{"name" => "user_id", "type" => "int8"}
  ]

  @ts "2021-11-05T17:20:51.52406+00:00"

  @subscription_id "417e76fd-9bc5-4b3e-bd5d-a031389c4a6b"

  test "generate_record/1, INSERT" do
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
      is_rls_enabled: false,
      schema: "public",
      table: "todos",
      type: "INSERT",
      subscription_ids: MapSet.new([@subscription_id]),
      record: %{"details" => "test", "id" => 12, "user_id" => 1},
      errors: nil
    }

    assert expected == generate_record(record)
  end

  test "generate_record/1, UPDATE" do
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
      is_rls_enabled: false,
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

  test "generate_record/1, DELETE" do
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
      is_rls_enabled: false,
      schema: "public",
      table: "todos",
      type: "DELETE",
      subscription_ids: MapSet.new([@subscription_id]),
      old_record: %{"id" => 15},
      errors: nil
    }

    assert expected == generate_record(record)
  end

  test "generate_record/1, INSERT, large payload error present" do
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
      is_rls_enabled: false,
      schema: "public",
      table: "todos",
      type: "INSERT",
      subscription_ids: MapSet.new([@subscription_id]),
      record: %{"details" => "test", "id" => 12, "user_id" => 1},
      errors: ["Error 413: Payload Too Large"]
    }

    assert expected == generate_record(record)
  end

  test "generate_record/1, INSERT, other errors present" do
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
      is_rls_enabled: false,
      schema: "public",
      table: "todos",
      type: "INSERT",
      subscription_ids: MapSet.new([@subscription_id]),
      record: %{},
      errors: ["Error..."]
    }

    assert expected == generate_record(record)
  end

  test "generate_record/1, UPDATE, large payload error present" do
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
      is_rls_enabled: false,
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

  test "generate_record/1, UPDATE, other errors present" do
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
      is_rls_enabled: false,
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

  test "generate_record/1, DELETE, large payload error present" do
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
      is_rls_enabled: false,
      schema: "public",
      table: "todos",
      type: "DELETE",
      subscription_ids: MapSet.new([@subscription_id]),
      old_record: %{"details" => "test", "id" => 12, "user_id" => 1},
      errors: ["Error 413: Payload Too Large"]
    }

    assert expected == generate_record(record)
  end

  test "generate_record/1, DELETE, other errors present" do
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
      is_rls_enabled: false,
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
