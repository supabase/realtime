defmodule Realtime.Tenants.Migrations.UnloggedMessagesTable do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute """
    -- ALTER TABLE realtime.messages SET UNLOGGED;
    """
  end
end
