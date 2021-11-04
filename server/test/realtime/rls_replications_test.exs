defmodule Realtime.RlsReplicationsTest do
  use ExUnit.Case
  import Realtime.RLS.Repo
  import Realtime.RLS.Replications

  @slot_name "test_realtime_slot_name"
  @undef_slot_name "undef_test_realtime_slot_name"
  @publication_time "supabase_realtime"

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "prepare_replication/2, create a new slot" do
    query("select pg_drop_replication_slot($1);", [@slot_name])
    expected = {:ok, %{create_slot: @slot_name, search_path: :set}}
    assert expected == prepare_replication(@slot_name, false)
  end

  test "prepare_replication/2, try to create a slot with an existing name" do
    res =
      case prepare_replication(@slot_name, false) do
        {:error, %Postgrex.Error{}} -> true
        _ -> false
      end

    assert res
  end

  @tag :qwe
  test "list_changes/2, empty response" do
    {:ok, res} = list_changes(@slot_name, @publication_time)
    assert res.rows == []
  end

  test "list_changes/2, response with changes" do
    # TODO: check by user_id
    query("insert into public.todos (details, user_id) VALUES ($1, $2)", ["test", 1])
    Process.sleep(500)
    {:ok, %{rows: [[record, _, _, _]]}} = list_changes(@slot_name, @publication_time)

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
end
