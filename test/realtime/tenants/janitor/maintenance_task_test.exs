defmodule Realtime.Tenants.Janitor.MaintenanceTaskTest do
  use Realtime.DataCase, async: true
  use Mimic

  alias Realtime.Tenants.Janitor.MaintenanceTask
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Tenants.Repo

  setup :set_mimic_from_context

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Realtime.Tenants.Cache.update_cache(tenant)

    %{tenant: tenant}
  end

  describe "run/1" do
    setup %{tenant: tenant} do
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      date_start = Date.utc_today() |> Date.add(-10)
      date_end = Date.utc_today()
      create_messages_partitions(conn, date_start, date_end)

      %{conn: conn}
    end

    test "cleans messages older than 72 hours", %{tenant: tenant, conn: conn} do
      utc_now = NaiveDateTime.utc_now()
      limit = NaiveDateTime.add(utc_now, -72, :hour)

      messages =
        for days <- -5..0 do
          inserted_at = NaiveDateTime.add(utc_now, days, :day)
          message_fixture(tenant, %{inserted_at: inserted_at})
        end
        |> MapSet.new()

      to_keep =
        messages
        |> Enum.reject(&(NaiveDateTime.compare(NaiveDateTime.beginning_of_day(limit), &1.inserted_at) == :gt))
        |> MapSet.new()

      assert MaintenanceTask.run(tenant.external_id) == :ok

      {:ok, res} = Repo.all(conn, from(m in Message), Message)
      current = MapSet.new(res)

      assert MapSet.difference(current, to_keep) |> MapSet.size() == 0
    end

    test "creates the current messages partitions and drops the old ones", %{tenant: tenant, conn: conn} do
      assert MaintenanceTask.run(tenant.external_id) == :ok

      today = Date.utc_today()
      dates = Date.range(Date.add(today, -3), Date.add(today, 3))

      %{rows: rows} =
        Postgrex.query!(
          conn,
          "SELECT tablename from pg_catalog.pg_tables where schemaname = 'realtime' and tablename like 'messages_%'",
          []
        )

      partitions = MapSet.new(rows, fn [name] -> name end)

      expected_names =
        MapSet.new(dates, fn date -> "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}" end)

      assert MapSet.equal?(partitions, expected_names)
    end
  end

  describe "connection lifecycle" do
    setup do
      %{task_supervisor: start_supervised!(Task.Supervisor)}
    end

    test "the connection is closed once the janitor task finishes", ctx do
      %{tenant: tenant, task_supervisor: task_supervisor} = ctx
      test_pid = self()

      # Hold maintenance open so the connection can be observed while the task is still running
      expect(Messages, :delete_old_messages, fn conn ->
        send(test_pid, {:connected, conn})

        receive do
          :continue -> :ok
        end
      end)

      task = run_in_task(task_supervisor, tenant)

      assert_receive {:connected, conn}, 5000
      assert Process.alive?(conn)

      send(task.pid, :continue)

      assert_receive {:DOWN, _ref, :process, _pid, :normal}, 5000
      assert eventually(fn -> !Process.alive?(conn) end, sleep: 10)
    end

    test "the connection is closed when maintenance raises", ctx do
      %{tenant: tenant, task_supervisor: task_supervisor} = ctx
      test_pid = self()

      expect(Messages, :delete_old_messages, fn conn ->
        send(test_pid, {:connected, conn})

        receive do
          :continue -> raise "maintenance failed"
        end
      end)

      task = run_in_task(task_supervisor, tenant)

      assert_receive {:connected, conn}, 5000
      assert Process.alive?(conn)

      send(task.pid, :continue)

      assert_receive {:DOWN, _ref, :process, _pid, {%RuntimeError{message: "maintenance failed"}, _}}, 5000
      assert eventually(fn -> !Process.alive?(conn) end, sleep: 10)
    end
  end

  test "exits if fails to remove old messages" do
    extensions = [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "postgres",
          "db_port" => "11111",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1",
          "ssl_enforced" => false
        }
      }
    ]

    tenant = tenant_fixture(%{extensions: extensions})
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Realtime.Tenants.Cache.update_cache(tenant)

    Process.flag(:trap_exit, true)

    t =
      Task.async(fn ->
        MaintenanceTask.run(tenant.external_id)
      end)

    pid = t.pid
    ref = t.ref
    assert_receive {:EXIT, ^pid, :killed}
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  # Run maintenance the way the Janitor does: inside a task, which owns the connection.
  # The task waits for :go so Mimic can allow it before the expectation is called.
  defp run_in_task(task_supervisor, tenant) do
    test_pid = self()

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        receive do
          :go -> MaintenanceTask.run(tenant.external_id)
        end
      end)

    Mimic.allow(Messages, test_pid, task.pid)
    send(task.pid, :go)

    task
  end
end
