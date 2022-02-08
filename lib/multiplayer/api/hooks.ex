defmodule Multiplayer.Api.Hooks do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "hooks" do
    field(:event, :string)
    field(:type, :string)
    field(:url, :string)

    belongs_to(:tenant, Multiplayer.Api.Tenant)

    timestamps()
  end

  @doc false
  def changeset(hooks, attrs) do
    hooks
    |> cast(attrs, [:type, :event, :url])
    |> validate_required([:type, :event, :url])
  end
end
