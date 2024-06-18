defmodule Realtime.Tenants.BatchBroadcast do
  @moduledoc """
  Virtual schema with a representation of a batched broadcast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    embeds_many :messages, Message do
      field :event, :string
      field :topic, :string
      field :payload, :map
      field :private, :boolean, default: false
    end
  end

  def changeset(payload, attrs) do
    payload
    |> cast(attrs, [])
    |> cast_embed(:messages, required: true, with: &message_changeset/2)
  end

  def message_changeset(message, attrs) do
    message
    |> cast(attrs, [:topic, :payload, :event, :private])
    |> maybe_put_private_change()
    |> validate_required([:topic, :payload, :event])
  end

  defp maybe_put_private_change(changeset) do
    case get_change(changeset, :private) do
      nil -> put_change(changeset, :private, false)
      _ -> changeset
    end
  end
end
