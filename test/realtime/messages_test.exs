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

    %{conn: conn, tenant: tenant}
  end

  test "delete_old_messages/1 deletes messages older than 72 hours", %{conn: conn, tenant: tenant} do
    utc_now = NaiveDateTime.utc_now()
    limit = NaiveDateTime.add(utc_now, -72, :hour)

    messages =
      for days <- -5..0 do
        inserted_at = NaiveDateTime.add(utc_now, days, :day)
        message_fixture(tenant, %{inserted_at: inserted_at})
      end

    to_keep =
      Enum.reject(
        messages,
        &(NaiveDateTime.compare(limit, &1.inserted_at) == :gt)
      )

    Messages.delete_old_messages(conn)
    {:ok, current} = Repo.all(conn, from(m in Message), Message)

    assert current == to_keep
  end
end
