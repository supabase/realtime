defmodule Realtime.Tenants.Migrations.RecreateEntityIndexUsingBtree do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("drop index if exists \"realtime\".\"ix_realtime_subscription_entity\"")

    execute(
      "create index if not exists ix_realtime_subscription_entity on realtime.subscription using btree (entity)"
    )
  end
end
