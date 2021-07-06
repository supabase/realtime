defmodule Multiplayer.Api.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field :name, :string
    field :external_id, :string
    field :jwt_secret, :string
    has_many :scopes, Multiplayer.Api.Scope

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :external_id, :jwt_secret])
    |> validate_required([:name])
  end
end
