defmodule Realtime.RlsReplicationsTest do
  use ExUnit.Case
  import Realtime.RLS.Repo
  import Realtime.RLS.Replications

  @slot_name "test_realtime_slot_name"
  @publication_name "supabase_realtime_test"
  @max_changes 10
  @max_record_bytes 1_048_576

  setup_all do
    start_supervised(Realtime.RLS.Repo)

    %Postgrex.Result{rows: [[oid]]} =
      query!("select oid from pg_class where relname = $1;", ["todos"])

    query!("truncate realtime.subscription restart identity;")

    query!(
      "insert into realtime.subscription (subscription_id, entity, claims) VALUES ($1, $2, $3)",
      [Ecto.UUID.bingenerate(), oid, %{"role" => "authenticated"}]
    )

    :ok
  end

  setup do
    query("select pg_drop_replication_slot($1);", [@slot_name])
    :ok
  end

  test "prepare_replication/2, create a new slot" do
    assert {:ok, @slot_name} = prepare_replication(@slot_name, false)
  end

  test "prepare_replication/2, try to create a slot with an existing name" do
    slot_query = "select 1 from pg_replication_slots where slot_name = $1"

    assert {:ok, %Postgrex.Result{rows: []}} = query(slot_query, [@slot_name])
    assert {:ok, @slot_name} = prepare_replication(@slot_name, false)
    assert {:ok, %Postgrex.Result{rows: [[1]]}} = query(slot_query, [@slot_name])
    assert {:ok, @slot_name} = prepare_replication(@slot_name, false)
  end

  test "list_changes/2, empty response" do
    prepare_replication(@slot_name, false)
    {:ok, res} = list_changes(@slot_name, @publication_name, @max_changes, @max_record_bytes)

    res2 =
      Enum.filter(res.rows, fn
        %{"schema" => "public"} -> true
        _ -> false
      end)

    assert res2 == []
  end

  test "list_changes/2, response with changes" do
    prepare_replication(@slot_name, false)
    # TODO: check by user_id
    query("insert into public.todos (details, user_id) VALUES ($1, $2)", ["test", 1])
    Process.sleep(500)

    {:ok, %{rows: [[record, _, _, _]]}} =
      list_changes(@slot_name, @publication_name, @max_changes, @max_record_bytes)

    columns = [
      %{"name" => "id", "type" => "int8"},
      %{"name" => "details", "type" => "text"},
      %{"name" => "user_id", "type" => "int8"}
    ]

    assert record["columns"] == columns
    assert record["schema"] == "public"
    assert record["table"] == "todos"
    assert record["type"] == "INSERT"
    assert record["record"]["details"] == "test"
    assert record["record"]["user_id"] == 1
  end

  test "list_changes/2, response with changes, update changes surpass max record size" do
    prepare_replication(@slot_name, false)
    query("insert into public.todos (details, user_id) VALUES ($1, $2)", ["test", 1])
    query("update public.todos set details = repeat('w', 1 * 1024 * 1024)::text where id = 1", [])
    Process.sleep(500)

    {:ok, %{rows: [_, [record, _, _, errors]]}} =
      list_changes(@slot_name, @publication_name, @max_changes, @max_record_bytes)

    columns = [
      %{"name" => "id", "type" => "int8"},
      %{"name" => "details", "type" => "text"},
      %{"name" => "user_id", "type" => "int8"}
    ]

    assert record["columns"] == columns
    assert record["schema"] == "public"
    assert record["table"] == "todos"
    assert record["type"] == "UPDATE"
    assert record["old_record"] == %{"id" => 1}
    assert record["record"] == %{"id" => 1, "user_id" => 1}
    assert errors == ["Error 413: Payload Too Large"]
  end
end
