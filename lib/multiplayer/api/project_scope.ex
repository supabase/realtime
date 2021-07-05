defmodule Multiplayer.Api.ProjectScope do
  use Ecto.Schema
  import Ecto.Changeset

  schema "project_scopes" do
    field :project_id, :id
    field :host, :string

    timestamps()
  end

  @doc false
  def changeset(project_scope, attrs) do
    project_scope
    |> cast(attrs, [:host])
    |> validate_required([:host])
  end
end
