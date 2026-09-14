defmodule Realtime.Tenants.Migrations.DelegateMessagesGrantsToPostgres do
  @moduledoc false

  use Ecto.Migration

  def up do
    execute("GRANT SELECT, INSERT ON realtime.messages TO postgres WITH GRANT OPTION")
  end

  def down do
    execute("REVOKE GRANT OPTION FOR SELECT, INSERT ON realtime.messages FROM postgres CASCADE")
  end
end
