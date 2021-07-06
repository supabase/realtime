defmodule Multiplayer.Api.Scope do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "scopes" do
    field :host, :string

    belongs_to :project, Multiplayer.Api.Project

    timestamps()
  end

  @doc false
  def changeset(scope, attrs) do
    scope
    |> cast(attrs, [:host, :project_id])
    |> validate_required([:host, :project_id])
  end
end
