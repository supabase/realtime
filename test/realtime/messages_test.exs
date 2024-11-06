defmodule Realtime.MessagesTest do
  use Realtime.DataCase, async: true

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Messages
  alias Realtime.Repo
  alias Realtime.Tenants.Migrations

  setup do
    tenant = tenant_fixture()
    [%{settings: settings} | _] = tenant.extensions
    migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}
    Migrations.run_migrations(migrations)

    {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
    clean_table(conn, "realtime", "messages")
    date_start = Date.utc_today() |> Date.add(-10)
    date_end = Date.utc_today()
    create_messages_partitions(conn, date_start, date_end)
    %{conn: conn, tenant: tenant, date_start: date_start, date_end: date_end}
  end

  test "delete_old_messages/1 deletes messages older than 72 hours", %{
    conn: conn,
    tenant: tenant,
    date_start: date_start,
    date_end: date_end
  } do
    utc_now = NaiveDateTime.utc_now()
    limit = NaiveDateTime.add(utc_now, -72, :hour)

    messages =
      for date <- Date.range(date_start, date_end) do
        inserted_at = date |> NaiveDateTime.new!(Time.new!(0, 0, 0))
        message_fixture(tenant, %{inserted_at: inserted_at})
      end

    assert length(messages) == 11

    to_keep =
      Enum.reject(
        messages,
        &(NaiveDateTime.compare(limit, &1.inserted_at) == :gt)
      )

    assert :ok = Messages.delete_old_messages(conn)
    {:ok, current} = Repo.all(conn, from(m in Message), Message)

    assert current == to_keep
  end
end
