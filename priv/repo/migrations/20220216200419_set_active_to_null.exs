defmodule Multiplayer.Repo.Migrations.SetActiveToNull do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE public.tenants ALTER COLUMN active SET NOT NULL;")
    execute("ALTER TABLE public.tenants ALTER COLUMN active SET DEFAULT false;")
  end
end
