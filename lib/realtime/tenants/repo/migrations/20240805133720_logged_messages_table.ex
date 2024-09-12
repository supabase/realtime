defmodule Realtime.Tenants.Migrations.LoggedMessagesTable do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute """
    -- ALTER TABLE realtime.messages SET LOGGED;
    """
  end
end
