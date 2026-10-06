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

  @doc """
  Normalizes a client-provided presence key into one Phoenix.Presence can track.
  """
  @spec normalize_key(term()) :: {:ok, String.t() | number() | boolean()} | :error
  def normalize_key(key) when is_binary(key) or is_number(key) or is_boolean(key), do: {:ok, key}
  def normalize_key(_), do: :error

  defp validate_key(changeset) do
    case get_change(changeset, :key) do
      nil ->
        changeset

      key ->
        case normalize_key(key) do
          {:ok, _} -> changeset
          :error -> add_error(changeset, :key, "unable to parse, expected a string")
        end
    end
  end
end
