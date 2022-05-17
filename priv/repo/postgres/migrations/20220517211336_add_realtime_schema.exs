defmodule Realtime.Repo.Migrations.AddRealtimeSchema do
  use Ecto.Migration

  def up do
    execute("create schema if not exists realtime")
  end

  def down do
    execute("drop schema realtime cascade")
  end
end
