defmodule Multiplayer.Api.Hooks do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hooks" do
    field :event, :string
    field :type, :string
    field :url, :string

    timestamps()
  end

  @doc false
  def changeset(hooks, attrs) do
    hooks
    |> cast(attrs, [:type, :event, :url])
    |> validate_required([:type, :event, :url])
  end
end
