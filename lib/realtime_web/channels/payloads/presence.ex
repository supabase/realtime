defmodule RealtimeWeb.Channels.Payloads.Presence do
  @moduledoc """
  Validate presence field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join

  embedded_schema do
    field :enabled, :boolean, default: true
    field :key, :string
  end

  def changeset(presence, attrs) do
    presence
    |> cast(attrs, [:enabled], message: &Join.error_message/2)
    |> cast_to_string(attrs, :key, &UUID.uuid1/0)
  end

  defp cast_to_string(changeset, attrs, field, default_fun) do
    case Map.get(attrs, Atom.to_string(field)) do
      nil -> put_change(changeset, field, default_fun.())
      value when is_binary(value) -> put_change(changeset, field, value)
      value -> put_change(changeset, field, "#{value}")
    end
  end
end
