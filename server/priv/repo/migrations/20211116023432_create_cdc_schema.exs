defmodule Realtime.RLS.Repo.Migrations.CreateCdcSchema do
  use Ecto.Migration

  def change do
    execute "create schema if not exists cdc"
    execute "grant usage on schema cdc to postgres, authenticated"
  end
end
