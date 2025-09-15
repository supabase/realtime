defmodule Realtime.Tenants.Janitor.MaintenanceTaskTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Janitor.MaintenanceTask
  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Repo

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

    %{tenant: tenant}
  end

  test "cleans messages older than 72 hours and creates partitions", %{tenant: tenant} do
    {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

    utc_now = NaiveDateTime.utc_now()
    limit = NaiveDateTime.add(utc_now, -72, :hour)

    date_start = Date.utc_today() |> Date.add(-10)
    date_end = Date.utc_today()
    create_messages_partitions(conn, date_start, date_end)

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

    verify_partitions(conn)

    current = MapSet.new(res)

    assert MapSet.difference(current, to_keep) |> MapSet.size() == 0
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
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

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

  defp verify_partitions(conn) do
    today = Date.utc_today()
    yesterday = Date.add(today, -3)
    future = Date.add(today, 3)
    dates = Date.range(yesterday, future)

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
