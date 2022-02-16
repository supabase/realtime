defmodule Multiplayer.Repo.Migrations.UniqExternalId do
  use Ecto.Migration

  def change do
    execute(
      "CREATE UNIQUE INDEX tenants_uniq_ext_id ON public.tenants USING BTREE (external_id);"
    )
  end
end
