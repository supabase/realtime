defmodule Multiplayer.Api.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :external_id, :string
    field :jwt_secret, :string

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :external_id, :jwt_secret])
    |> validate_required([:name, :external_id, :jwt_secret])
  end
end
