defmodule Realtime.Tenants.Migrations.RealtimeSubscriptionCreateSequence do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute """
        CREATE SEQUENCE IF NOT EXISTS realtime.realtime_subscription_id_seq
    """

    execute """
        ALTER TABLE realtime.subscription ALTER COLUMN subscription_id SET DEFAULT nextval('realtime.realtime_subscription_id_seq');
    """
  end
end
