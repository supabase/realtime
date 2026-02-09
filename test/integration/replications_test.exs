defmodule Realtime.Integration.ReplicationsTest do
  use Realtime.DataCase, async: false

  alias Extensions.PostgresCdcRls.Replications
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  @publication "supabase_realtime_test"
  @poll_interval 100

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    {:ok, conn} =
      tenant
      |> Database.from_tenant("realtime_rls")
      |> Map.from_struct()
      |> Keyword.new()
      |> Postgrex.start_link()

    slot_name = "supabase_realtime_test_slot_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        Postgrex.query(conn, "select pg_drop_replication_slot($1)", [slot_name])
      catch
        _, _ -> :ok
      end
    end)

    {:ok, subscription_params} = Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public"})
    params_list = [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}]
    {:ok, _} = Subscriptions.create(conn, @publication, params_list, self(), self())
    {:ok, _} = Replications.prepare_replication(conn, slot_name)

    # Drain any setup changes
    Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

    %{conn: conn, slot_name: slot_name}
  end

  describe "replication polling lifecycle" do
    test "prepare, poll, consume full cycle", %{conn: conn, slot_name: slot_name} do
      # Empty slot short-circuits via peek
      {time, result} =
        :timer.tc(fn ->
          Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)
        end)

      assert {:ok, %Postgrex.Result{num_rows: 0}} = result
      assert time < 50_000, "Expected peek short-circuit under 50ms, took #{div(time, 1000)}ms"

      Process.sleep(@poll_interval)

      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('row_1')", [])
      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('row_2')", [])
      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('row_3')", [])

      Process.sleep(@poll_interval)

      {:ok, %Postgrex.Result{num_rows: 3, rows: rows}} =
        Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      [row | _] = rows
      assert Enum.at(row, 0) == "INSERT"
      assert Enum.at(row, 1) == "public"
      assert Enum.at(row, 2) == "test"

      Process.sleep(@poll_interval)

      {:ok, %Postgrex.Result{num_rows: 0}} =
        Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)
    end

    test "polls empty multiple times then captures a change when it arrives", %{conn: conn, slot_name: slot_name} do
      for _ <- 1..5 do
        {:ok, %Postgrex.Result{num_rows: 0}} =
          Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

        Process.sleep(@poll_interval)
      end

      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('delayed_arrival')", [])
      Process.sleep(@poll_interval)

      {:ok, %Postgrex.Result{num_rows: 1, rows: [row]}} =
        Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      assert Enum.at(row, 0) == "INSERT"
      assert Enum.at(row, 1) == "public"
      assert Enum.at(row, 2) == "test"

      Process.sleep(@poll_interval)

      {:ok, %Postgrex.Result{num_rows: 0}} =
        Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)
    end

    test "prepare_replication is idempotent", %{conn: conn, slot_name: slot_name} do
      {:ok, _} = Replications.prepare_replication(conn, slot_name)
      Process.sleep(@poll_interval)
      {:ok, _} = Replications.prepare_replication(conn, slot_name)
    end

    test "terminate_backend returns slot_not_found for unknown slots", %{conn: conn} do
      assert {:error, :slot_not_found} =
               Replications.terminate_backend(conn, "nonexistent_slot_#{System.unique_integer([:positive])}")
    end

    test "get_pg_stat_activity_diff returns elapsed seconds for active connection", %{conn: conn} do
      {:ok, %Postgrex.Result{rows: [[pid]]}} = Postgrex.query(conn, "SELECT pg_backend_pid()", [])
      Postgrex.query!(conn, "SET application_name = 'realtime_rls'", [])
      Process.sleep(@poll_interval)

      assert {:ok, diff} = Replications.get_pg_stat_activity_diff(conn, pid)
      assert is_integer(diff)
    end
  end
end
