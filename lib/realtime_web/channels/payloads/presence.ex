defmodule RealtimeWeb.Channels.Payloads.Presence do
  @moduledoc """
  Validate presence field of the join payload.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias RealtimeWeb.Channels.Payloads.Join
  alias RealtimeWeb.Channels.Payloads.FlexibleBoolean

  embedded_schema do
    field :enabled, FlexibleBoolean, default: false
    field :key, :any, virtual: true
  end

  def changeset(presence, attrs) do
    presence
    |> cast(attrs, [:enabled, :key], message: &Join.error_message/2)
    |> validate_key()
  end

  # key is cast as :any so a string or numeric key is accepted, but a non-scalar key (map, list)
  # must be rejected here: it would otherwise crash Phoenix.Presence, which expects a string key.
  defp validate_key(changeset) do
    case get_change(changeset, :key) do
      key when is_nil(key) or is_binary(key) or is_number(key) -> changeset
      _ -> add_error(changeset, :key, "unable to parse, expected a string")
    end
  end
end
